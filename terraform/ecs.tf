#---------- ECS Cluster ----------

resource "aws_ecs_cluster" "management-api-cluster" {
  name = "burrow-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

#---------- IAM Roles ----------

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
          "s3:GetObject",
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:PutObjectTagging",
          "s3:GetObjectTagging",
          "s3:CopyObject",
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
          "${aws_dynamodb_table.documents-table.arn}/index/*",
          aws_dynamodb_table.users-table.arn,
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
          "s3:GetObjectTagging",
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

#---------- CloudWatch Log Groups ----------

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

resource "aws_cloudwatch_log_group" "query_api" {
  name              = "/ecs/query-api-tf"
  retention_in_days = 7

  tags = {
    Name = "query-api-logs-tf"
  }
}

#---------- Task Definitions ----------

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
        },
        {
          name      = "ORIGIN_VERIFY_TOKEN"
          valueFrom = aws_secretsmanager_secret.origin_verify.arn
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
          name      = "API_TOKEN"
          valueFrom = aws_secretsmanager_secret.query_api_token.arn
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

#---------- ECS Services ----------

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

  depends_on = [aws_nat_gateway.burrow_nat]
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

  depends_on = [aws_nat_gateway.burrow_nat]
}
