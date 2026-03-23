#---------- Application S3 Bucket ----------

resource "random_id" "s3-bucket-suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "rag-pipeline-documents-${random_id.s3-bucket-suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket      = aws_s3_bucket.bucket.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "deleted_documents" {
  bucket = aws_s3_bucket.bucket.id

  rule {
    id     = "expire-deleted-documents"
    status = "Enabled"

    filter {
      prefix = "deleted/"
    }

    expiration {
      days = 90
    }
  }
}

#---------- EventBridge Rules ----------

resource "aws_cloudwatch_event_rule" "s3_object_created_rule" {
  name           = "s3-object-created-rule"
  description    = "Rule to capture S3 object creation events"
  event_bus_name = "default"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.bucket.id]
      }
      object = {
        key = [{
          anything-but = { prefix = "deleted/" }
        }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_target" {
  rule      = aws_cloudwatch_event_rule.s3_object_created_rule.name
  target_id = "TriggerECSTask"
  arn       = aws_ecs_cluster.management-api-cluster.arn
  role_arn  = aws_iam_role.eventbridge_ecs_role.arn

  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.ingestion-terraform.arn
    launch_type         = "FARGATE"
    platform_version    = "LATEST"

    network_configuration {
      subnets          = [var.private_subnet_1_id, var.private_subnet_2_id]
      assign_public_ip = false
      security_groups  = [aws_security_group.ingestion_task_sg.id]
    }
  }

  input_transformer {
    input_paths = {
      detail_bucket_name = "$.detail.bucket.name"
      detail_object_key  = "$.detail.object.key"
      detail_event_name  = "$.detail-type"
    }
    input_template = <<-EOT
{
  "containerOverrides": [
    {
      "name": "ingestion-container",
      "environment": [
        {
          "name": "S3_BUCKET_NAME",
          "value": "<detail_bucket_name>"
        },
        {
          "name": "S3_OBJECT_KEY",
          "value": "<detail_object_key>"
        },
        {
          "name": "EVENT_TYPE",
          "value": "<detail_event_name>"
        }
      ]
    }
  ]
}
EOT
  }
  retry_policy {
    maximum_retry_attempts       = 5
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

resource "aws_cloudwatch_event_rule" "s3_object_tags_added_rule" {
  name           = "s3-object-tags-added-rule"
  description    = "Rule to capture S3 object tagging events for deletion workflow"
  event_bus_name = "default"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Tags Added"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.bucket.id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_delete_target" {
  rule      = aws_cloudwatch_event_rule.s3_object_tags_added_rule.name
  target_id = "TriggerECSTaskDelete"
  arn       = aws_ecs_cluster.management-api-cluster.arn
  role_arn  = aws_iam_role.eventbridge_ecs_role.arn

  ecs_target {
    task_count          = 1
    task_definition_arn = aws_ecs_task_definition.ingestion-terraform.arn
    launch_type         = "FARGATE"
    platform_version    = "LATEST"

    network_configuration {
      subnets          = [var.private_subnet_1_id, var.private_subnet_2_id]
      assign_public_ip = false
      security_groups  = [aws_security_group.ingestion_task_sg.id]
    }
  }

  input_transformer {
    input_paths = {
      detail_bucket_name = "$.detail.bucket.name"
      detail_object_key  = "$.detail.object.key"
      detail_event_name  = "$.detail-type"
    }
    input_template = <<-EOT
{
  "containerOverrides": [
    {
      "name": "ingestion-container",
      "environment": [
        {
          "name": "S3_BUCKET_NAME",
          "value": "<detail_bucket_name>"
        },
        {
          "name": "S3_OBJECT_KEY",
          "value": "<detail_object_key>"
        },
        {
          "name": "EVENT_TYPE",
          "value": "<detail_event_name>"
        }
      ]
    }
  ]
}
EOT
  }
  retry_policy {
    maximum_retry_attempts       = 5
    maximum_event_age_in_seconds = 3600
  }

  dead_letter_config {
    arn = aws_sqs_queue.eventbridge_dlq.arn
  }
}

#---------- EventBridge IAM Role ----------

resource "aws_iam_role" "eventbridge_ecs_role" {
  name = "eventbridge-ecs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "eventbridge-ecs-role"
  }
}

resource "aws_iam_role_policy" "eventbridge_ecs_policy" {
  name = "eventbridge-ecs-policy"
  role = aws_iam_role.eventbridge_ecs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecs:RunTask"
        ]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = ["*"]
        Condition = {
          StringLike = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      }
    ]
  })
}

#---------- ECS Task Failure Monitoring ----------

resource "aws_cloudwatch_event_rule" "ecs_task_failed_rule" {
  name           = "ecs-task-failed-rule"
  description    = "Failed ingestion ECS tasks (STOPPED with non-zero exitCode)"
  event_bus_name = "default"

  event_pattern = jsonencode({
    "source" : ["aws.ecs"],
    "detail-type" : ["ECS Task State Change"],
    "detail" : {
      "clusterArn" : [aws_ecs_cluster.management-api-cluster.arn],

      "group" : ["family:ingestion-terraform"],

      "lastStatus" : ["STOPPED"],

      "containers" : {
        "exitCode" : [{
          "anything-but" : 0
        }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_failed_to_sqs" {
  rule      = aws_cloudwatch_event_rule.ecs_task_failed_rule.name
  target_id = "SendFailedIngestionTasksToSqs"
  arn       = aws_sqs_queue.eventbridge_dlq.arn
}

resource "aws_cloudwatch_event_rule" "ecs_task_stopped_no_exit_rule" {
  name           = "ecs-task-stopped-no-exit-rule"
  description    = "Tasks that stopped before container started (provisioning failures)"
  event_bus_name = "default"

  event_pattern = jsonencode({
    "source" : ["aws.ecs"],
    "detail-type" : ["ECS Task State Change"],
    "detail" : {
      "clusterArn" : [aws_ecs_cluster.management-api-cluster.arn],
      "group" : ["family:ingestion-terraform"],
      "lastStatus" : ["STOPPED"],
      "containers" : {
        "exitCode" : [{ "exists" : false }]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_stopped_no_exit_to_sqs" {
  rule      = aws_cloudwatch_event_rule.ecs_task_stopped_no_exit_rule.name
  target_id = "SendNoExitTasksToSqs"
  arn       = aws_sqs_queue.eventbridge_dlq.arn
}

#---------- SQS Dead Letter Queue ----------

resource "aws_sqs_queue" "eventbridge_dlq" {
  name = "burrow-eventbridge-dlq"

  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 70

  tags = {
    Name = "burrow-eventbridge-dlq"
  }
}

resource "aws_sqs_queue_policy" "eventbridge_dlq_policy" {
  queue_url = aws_sqs_queue.eventbridge_dlq.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEventBridgeToSendMessages"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.eventbridge_dlq.arn
      }
    ]
  })
}

#---------- DLQ Lambda ----------

resource "aws_iam_role" "eventbridge_dlq_lambda_role" {
  name = "eventbridge-dlq-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge_dlq_lambda_all" {
  name = "eventbridge-dlq-lambda-all"
  role = aws_iam_role.eventbridge_dlq_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LambdaLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      },
      {
        Sid    = "SqsDlqAccess"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.eventbridge_dlq.arn
      },
      {
        Sid    = "ReadApiTokens"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.origin_verify.arn,
          aws_secretsmanager_secret.ingestion-api-token.arn,
          aws_secretsmanager_secret.aurora_db_password.arn
        ]
      },
      {
        Sid    = "VpcAccess"
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "eventbridge_dlq_handler" {
  function_name = "burrow-eventbridge-dlq-handler"
  role          = aws_iam_role.eventbridge_dlq_lambda_role.arn

  runtime = "python3.12"
  handler = "index.handler"

  filename         = "../lambdas/eventbridge-dlq/eventbridge-dlq.zip"
  source_code_hash = filebase64sha256("../lambdas/eventbridge-dlq/eventbridge-dlq.zip")

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      ALB_BASE_URL            = "http://${aws_lb.burrow.dns_name}"
      DOCS_API_PATH           = "/api/documents"
      INGESTION_API_TOKEN_ARN = aws_secretsmanager_secret.ingestion-api-token.arn
      ORIGIN_VERIFY_ARN       = aws_secretsmanager_secret.origin_verify.arn
      DB_HOST                 = aws_rds_cluster.tf_aurora_pg.reader_endpoint
      DB_PORT                 = "5432"
      DB_NAME                 = "burrowdb"
      DB_USER                 = "burrow_admin"
      DB_PASSWORD_SECRET_ARN  = aws_secretsmanager_secret.aurora_db_password.arn
    }
  }

  vpc_config {
    subnet_ids         = [var.private_subnet_1_id, var.private_subnet_2_id]
    security_group_ids = [aws_security_group.dlq_lambda_sg.id]
  }
}

resource "aws_lambda_event_source_mapping" "eventbridge_dlq_to_lambda" {
  event_source_arn = aws_sqs_queue.eventbridge_dlq.arn
  function_name    = aws_lambda_function.eventbridge_dlq_handler.arn
  batch_size       = 8
}

#---------- pgvector Initialization Lambda ----------

resource "aws_lambda_function" "init_pgvector" {
  function_name = "burrow-init-pgvector"
  role          = aws_iam_role.eventbridge_dlq_lambda_role.arn

  runtime = "python3.12"
  handler = "index.handler"

  filename         = "../lambdas/init-pgvector/init-pgvector.zip"
  source_code_hash = filebase64sha256("../lambdas/init-pgvector/init-pgvector.zip")

  timeout     = 60
  memory_size = 256

  environment {
    variables = {
      DB_ENDPOINT            = aws_rds_cluster.tf_aurora_pg.endpoint
      DB_NAME                = "burrowdb"
      DB_USER                = "burrow_admin"
      DB_PASSWORD_SECRET_ARN = aws_secretsmanager_secret.aurora_db_password.arn
    }
  }

  vpc_config {
    subnet_ids         = [var.private_subnet_1_id, var.private_subnet_2_id]
    security_group_ids = [aws_security_group.dlq_lambda_sg.id]
  }
}

data "aws_lambda_invocation" "init_pgvector" {
  function_name = aws_lambda_function.init_pgvector.function_name
  input         = jsonencode({})
  depends_on    = [aws_rds_cluster_instance.tf_aurora_pg_instance]
}
