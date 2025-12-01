resource "aws_lb" "burrow" {
  name               = "burrow"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [var.public_subnet_1_id, var.public_subnet_2_id]

  tags = {
    Environment = "production"
  }
}

resource "aws_security_group" "lb_sg" {
  name        = "alb-security-group"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "alb-security-group"
  }
}

resource "aws_vpc_security_group_ingress_rule" "lb_http" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "lb_egress" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "ecs_service" {
  name        = "ecs-service-sg"
  description = "Security group for ECS service"
  vpc_id      = var.vpc_id

  tags = {
    Name = "ecs-service-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_service.id
  referenced_security_group_id = aws_security_group.lb_sg.id
  from_port                    = 3000
  ip_protocol                  = "tcp"
  to_port                      = 3000
}

resource "aws_vpc_security_group_egress_rule" "ecs_egress" {
  security_group_id = aws_security_group.ecs_service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_lb_target_group" "management_api" {
  name        = "alb-target-group"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/health"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = {
    Name = "alb-target-group"
  }
}

resource "aws_dynamodb_table" "documents-table" {
  name         = "documents-terraform"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "documentId"

  attribute {
    name = "createdAt"
    type = "S"
  }

  attribute {
    name = "documentId"
    type = "S"
  }

  attribute {
    name = "status"
    type = "S"
  }

  global_secondary_index {
    name            = "status-createdAt-index"
    hash_key        = "status"
    range_key       = "createdAt"
    projection_type = "ALL"
  }

  tags = {
    Name        = "dynamodb-table-1"
    Environment = "production"
  }
}

resource "aws_dynamodb_table" "users-table" {
  name         = "users-terraform"
  billing_mode = "PAY_PER_REQUEST"
  table_class  = "STANDARD"
  hash_key     = "userName"

  attribute {
    name = "userName"
    type = "S"
  }

  tags = {
    Name        = "dynamodb-table-2"
    Environment = "production"
  }
}

resource "aws_ecs_cluster" "management-api-cluster" {
  name = "burrow-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

resource "aws_ecs_task_definition" "management-api" {
  family                   = "management-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 3072
  container_definitions = jsonencode([
    {
      name  = "management-api"
      image = "docker.io/burrowai/management-api:main"
      portMappings = [
        {
          containerPort = 3000
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        {
          name  = "DYNAMODB_TABLE_NAME"
          value = "documents-terraform"
        },
        {
          name  = "AWS_REGION"
          value = "us-east-1"
        },
        {
          name  = "PORT"
          value = "3000"
        },
        {
          name  = "S3_BUCKET_NAME"
          value = aws_s3_bucket.bucket.id
        },
        {
          name  = "DYNAMODB_TABLE_USERS"
          value = "users-terraform"
        }
      ]
      secrets = [
        {
          name      = "ADMIN_PASSWORD"
          valueFrom = aws_secretsmanager_secret.admin-password.arn
        },
        {
          name      = "JWT_SECRET"
          valueFrom = aws_secretsmanager_secret.jwt-secret.arn
        },
        {
          name      = "INGESTION_API_TOKEN"
          valueFrom = aws_secretsmanager_secret.ingestion-api-token.arn
        }
      ]
      essential = true
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/management-api"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  task_role_arn      = aws_iam_role.ecs_task_role.arn
  execution_role_arn = aws_iam_role.ecs_execution_role.arn
}

resource "aws_iam_role" "ecs_task_role" {
  name = "ecs-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecs-task-role"
  }
}

resource "aws_iam_role_policy" "ecs_task_policy" {
  name = "ecs-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:DeleteItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          aws_dynamodb_table.documents-table.arn,
          aws_dynamodb_table.users-table.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role" "ingestion_task_role" {
  name = "ingestion-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ingestion-task-role"
  }
}

resource "aws_iam_role_policy" "ingestion_task_policy" {
  name = "ingestion-task-policy"
  role = aws_iam_role.ingestion_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.bucket.arn,
          "${aws_s3_bucket.bucket.arn}/*"
        ]
      },
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "*"
      },
      {
        Sid    = "BedrockAccess"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "ecs-execution-role"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecs_execution_secrets_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_cloudwatch_log_group" "ecs_service" {
  name              = "/ecs/management-api"
  retention_in_days = 7

  tags = {
    Name = "ecs-service-logs"
  }
}

resource "aws_cloudwatch_log_group" "ingestion_terraform" {
  name              = "/ecs/ingestion-terraform"
  retention_in_days = 7

  tags = {
    Name = "ingestion-terraform-logs"
  }
}

resource "random_password" "admin-password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "jwt-secret" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "ingestion-api-token" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "admin-password" {
  name                    = "ragline/admin-password"
  description             = "Admin password for ragline application"
  recovery_window_in_days = 0

  tags = {
    Name = "ragline-admin-password"
  }
}

resource "aws_secretsmanager_secret_version" "admin-password" {
  secret_id     = aws_secretsmanager_secret.admin-password.id
  secret_string = random_password.admin-password.result
}

resource "aws_secretsmanager_secret" "jwt-secret" {
  name                    = "ragline/jwt-secret"
  description             = "JWT secret key for ragline application"
  recovery_window_in_days = 0

  tags = {
    Name = "ragline-jwt-secret"
  }
}

resource "aws_secretsmanager_secret_version" "jwt-secret" {
  secret_id     = aws_secretsmanager_secret.jwt-secret.id
  secret_string = random_password.jwt-secret.result
}

resource "aws_secretsmanager_secret" "ingestion-api-token" {
  name                    = "ragline/ingestion-api-token"
  description             = "API token for ingestion service"
  recovery_window_in_days = 0

  tags = {
    Name = "ragline-ingestion-api-token"
  }
}

resource "aws_secretsmanager_secret_version" "ingestion-api-token" {
  secret_id     = aws_secretsmanager_secret.ingestion-api-token.id
  secret_string = random_password.ingestion-api-token.result
}

resource "aws_ecs_service" "management-api-service" {
  name            = "management-api-service"
  cluster         = aws_ecs_cluster.management-api-cluster.id
  task_definition = aws_ecs_task_definition.management-api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.management_api.arn
    container_name   = "management-api"
    container_port   = 3000
  }

  network_configuration {
    subnets          = [var.private_subnet_1_id, var.private_subnet_2_id]
    assign_public_ip = false
    security_groups  = [aws_security_group.ecs_service.id]
  }
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "rag-pipeline-documents-${lower(random_id.s3-bucket-suffix.id)}"
  force_destroy = true
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket      = aws_s3_bucket.bucket.id
  eventbridge = true
}

resource "random_id" "s3-bucket-suffix" {
  byte_length = 4
}

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
}

resource "aws_cloudwatch_event_rule" "s3_object_deleted_rule" {
  name           = "s3-object-deleted-rule"
  description    = "Rule to capture S3 object deletion events"
  event_bus_name = "default"

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Deleted"]
    detail = {
      bucket = {
        name = [aws_s3_bucket.bucket.id]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ecs_task_delete_target" {
  rule      = aws_cloudwatch_event_rule.s3_object_deleted_rule.name
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
}

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

resource "aws_ecs_task_definition" "ingestion-terraform" {
  family                   = "ingestion-terraform"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 2048
  memory                   = 5120

  container_definitions = jsonencode([
    {
      name      = "ingestion-container"
      image     = "docker.io/burrowai/ingestion-task:main"
      essential = true
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]

      environment = [
        {
          name  = "DB_HOST"
          value = aws_rds_cluster.tf_aurora_pg.endpoint
        },
        {
          name  = "DB_PORT"
          value = "5432"
        },
        {
          name  = "DB_NAME"
          value = "burrowdb"
        },
        {
          name  = "DB_USER"
          value = "burrow_admin"
        },
        {
          name  = "ALB_BASE_URL"
          value = "http://${aws_lb.burrow.dns_name}"
        }
      ]

      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = aws_secretsmanager_secret.aurora_db_password.arn
        },
        {
          name      = "INGESTION_API_TOKEN"
          valueFrom = aws_secretsmanager_secret.ingestion-api-token.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/ingestion-terraform"
          "awslogs-create-group"  = "true"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  task_role_arn      = aws_iam_role.ingestion_task_role.arn
  execution_role_arn = aws_iam_role.ecs_execution_role.arn
}

resource "aws_security_group" "ingestion_task_sg" {
  name        = "tf-ingestion-task-sg"
  description = "Security group for ingestion ECS tasks"
  vpc_id      = var.vpc_id

  tags = {
    Name = "tf-ingestion-task-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "ingestion_task_egress" {
  security_group_id = aws_security_group.ingestion_task_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_db_subnet_group" "tf_aurora_subnets" {
  name       = "tf-aurora-private-subnets"
  subnet_ids = [var.private_subnet_1_id, var.private_subnet_2_id]

  tags = {
    Name = "tf-aurora-private-subnets"
  }
}

resource "aws_security_group" "tf_aurora_sg" {
  name        = "tf-aurora-pg-sg"
  description = "Security group for Aurora PostgreSQL"
  vpc_id      = var.vpc_id

  tags = {
    Name = "tf-aurora-pg-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "tf_aurora_from_ingestion" {
  security_group_id            = aws_security_group.tf_aurora_sg.id
  referenced_security_group_id = aws_security_group.ingestion_task_sg.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "tf_aurora_egress" {
  security_group_id = aws_security_group.tf_aurora_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "random_password" "tf_aurora_master_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "aurora_db_password" {
  name                    = "ragline/aurora-db-password"
  description             = "Aurora DB password for burrowdb"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aurora_db_password" {
  secret_id     = aws_secretsmanager_secret.aurora_db_password.id
  secret_string = random_password.tf_aurora_master_password.result
}

resource "aws_rds_cluster" "tf_aurora_pg" {
  cluster_identifier  = "burrow-aurora-tf"
  engine              = "aurora-postgresql"
  engine_version      = "17.4"
  engine_mode         = "provisioned"
  database_name       = "burrowdb"
  master_username     = "burrow_admin"
  master_password     = random_password.tf_aurora_master_password.result
  storage_encrypted   = true
  skip_final_snapshot = true

  db_subnet_group_name   = aws_db_subnet_group.tf_aurora_subnets.name
  vpc_security_group_ids = [aws_security_group.tf_aurora_sg.id]

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 8
    seconds_until_auto_pause = 300
  }

  tags = {
    Name = "burrow-aurora-tf"
  }
}

resource "aws_rds_cluster_instance" "tf_aurora_pg_instance" {
  identifier         = "burrow-aurora-tf-1"
  cluster_identifier = aws_rds_cluster.tf_aurora_pg.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.tf_aurora_pg.engine
  engine_version = aws_rds_cluster.tf_aurora_pg.engine_version

  publicly_accessible = false

  monitoring_interval          = 0
  performance_insights_enabled = false

  tags = {
    Name = "burrow-aurora-tf-1"
  }
}

resource "aws_lb_target_group" "query_api" {
  name        = "query-api-tg-tf"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    path                = "/query-service/health"
    protocol            = "HTTP"
    matcher             = "200"
  }

  tags = {
    Name = "query-api-tg"
  }
}

resource "aws_security_group" "query_service" {
  name        = "query-service-sg"
  description = "Security group for query ECS service"
  vpc_id      = var.vpc_id

  tags = {
    Name = "query-service-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "query_from_alb" {
  security_group_id            = aws_security_group.query_service.id
  referenced_security_group_id = aws_security_group.lb_sg.id
  from_port                    = 8000
  to_port                      = 8000
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "query_egress" {
  security_group_id = aws_security_group.query_service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_cloudwatch_log_group" "query_api" {
  name              = "/ecs/query-api-tf"
  retention_in_days = 7

  tags = {
    Name = "query-api-logs-tf"
  }
}

resource "aws_ecs_task_definition" "query_api" {
  family                   = "query-api-tf"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 3072

  container_definitions = jsonencode([
    {
      name      = "query-api"
      image     = "docker.io/burrowai/query-api:main"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      environment = [
        {
          name  = "DB_HOST"
          value = aws_rds_cluster.tf_aurora_pg.reader_endpoint
        },
        {
          name  = "DB_PORT"
          value = "5432"
        },
        {
          name  = "DB_NAME"
          value = "burrowdb"
        },
        {
          name  = "DB_USER"
          value = "burrow_admin"
        },
      ]
      secrets = [
        {
          name      = "DB_PASSWORD"
          valueFrom = aws_secretsmanager_secret.aurora_db_password.arn
        },
        {
          name      = "API_TOKEN"                                   # env var name inside container
          valueFrom = aws_secretsmanager_secret.query_api_token.arn # the secret we just created
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = "/ecs/query-api-tf"
          "awslogs-create-group"  = "true"
          "awslogs-region"        = "us-east-1"
          "awslogs-stream-prefix" = "ecs"
        }
      }
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64"
  }

  task_role_arn      = aws_iam_role.ingestion_task_role.arn
  execution_role_arn = aws_iam_role.ecs_execution_role.arn
}

resource "aws_ecs_service" "query_api_service" {
  name            = "query-api-tf"
  cluster         = aws_ecs_cluster.management-api-cluster.id
  task_definition = aws_ecs_task_definition.query_api.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.query_api.arn
    container_name   = "query-api"
    container_port   = 8000
  }

  network_configuration {
    subnets          = [var.private_subnet_1_id, var.private_subnet_2_id]
    assign_public_ip = false
    security_groups  = [aws_security_group.query_service.id]
  }
}

resource "aws_vpc_security_group_ingress_rule" "tf_aurora_from_query" {
  security_group_id            = aws_security_group.tf_aurora_sg.id
  referenced_security_group_id = aws_security_group.query_service.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

#ZACH Created random password for Query Api token
resource "random_password" "query_api_token" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

#ZACH Created secret for Query Api token
resource "aws_secretsmanager_secret" "query_api_token" {
  name                    = "ragline/query-api-token"
  description             = "API token for query-service"
  recovery_window_in_days = 0

  tags = {
    Name = "ragline-query-api-token"
  }
}

#ZACH Stored token in the secret
resource "aws_secretsmanager_secret_version" "query_api_token" {
  secret_id     = aws_secretsmanager_secret.query_api_token.id
  secret_string = random_password.query_api_token.result
}

#------ZACH Adding stuff for S3 frontend-------

# Created a suffix for bucket so it's unique
resource "random_id" "frontend_suffix" {
  byte_length = 4
}

# Created S3 bucket
resource "aws_s3_bucket" "frontend" {
  bucket        = "burrow-frontend-${random_id.frontend_suffix.hex}"
  force_destroy = true

  tags = {
    Name = "burrow-frontend"
  }
}

# Block all public access on S3 bucket
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Created CloudFront OAC
resource "aws_cloudfront_origin_access_control" "frontend_oac" {
  name                              = "burrow-frontend-oac"
  description                       = "OAC for burrow frontend S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Created CloudFront distribution
resource "aws_cloudfront_distribution" "burrow" {
  enabled             = true
  default_root_object = "index.html"

  # S3 origin (frontend)
  origin {
    domain_name = "${aws_s3_bucket.frontend.bucket}.s3.${var.region}.amazonaws.com"
    origin_id   = "s3-frontend-origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.frontend_oac.id
  }

  # ALB origin (APIs)
  origin {
    domain_name = aws_lb.burrow.dns_name
    origin_id   = "alb-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend-origin"
    viewer_protocol_policy = "allow-all"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    # CachingOptimized(managed aws policy)
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  ordered_cache_behavior {
    path_pattern           = "/api/*"
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "allow-all"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled(managed aws policy)
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # AllViewer(managed aws policy)
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  ordered_cache_behavior {
    path_pattern           = "/query-service/*"
    target_origin_id       = "alb-origin"
    viewer_protocol_policy = "allow-all"

    allowed_methods = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods  = ["GET", "HEAD"]

    # CachingDisabled(managed aws policy)
    cache_policy_id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

    # AllViewer(managed aws policy)
    origin_request_policy_id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = {
    Name = "burrow-cloudfront"
  }
}

# Created bucket policy to only allow CloudFront
resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontRead"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action = [
          "s3:GetObject"
        ]
        Resource = [
          "${aws_s3_bucket.frontend.arn}/*"
        ]
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.burrow.arn
          }
        }
      }
    ]
  })
}

# Updated ALB listener to have a fixed 404 default
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.burrow.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

# Created Listener Rule for management-api
resource "aws_lb_listener_rule" "management_api_rule" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 5

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.management_api.arn
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

# Created Listener Rule for query-api
resource "aws_lb_listener_rule" "query_api_rule" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.query_api.arn
  }

  condition {
    path_pattern {
      values = ["/query-service/*"]
    }
  }
}

#--------Copying Dist to bucket on apply--------
locals {
  frontend_dir   = "${path.module}/dist"
  frontend_files = fileset(local.frontend_dir, "**")

  mime_types = {
    html = "text/html"
    js   = "text/javascript"
    css  = "text/css"
    svg  = "image/svg+xml"
    json = "application/json"
    png  = "image/png"
    jpg  = "image/jpeg"
    jpeg = "image/jpeg"
    ico  = "image/x-icon"
    map  = "application/json"
  }
}

resource "aws_s3_object" "frontend_files" {
  for_each = local.frontend_files

  bucket = aws_s3_bucket.frontend.bucket
  key    = each.value
  source = "${local.frontend_dir}/${each.value}"
  etag   = filemd5("${local.frontend_dir}/${each.value}")

  # Grab the file extension and look up the content-type
  content_type = lookup(
    local.mime_types,
    # take the last segment after the dot: e.g. "index.html" -> "html"
    element(split(".", each.value), length(split(".", each.value)) - 1),
    "binary/octet-stream"
  )
}

