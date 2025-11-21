# One of us: make a brand new VPC manually (to meet pre-req)
# - make sure it has 2 public subnets & 2 private subnets)
# The other: figure out how to configure terraform
#  - figure out what account to use and S3 backend (store state in S3 bucket that we make rather than locally)
# Together: make alb, listener, target group
# - be able to: terraform apply, then terraform destroy
resource "aws_lb" "test-lb-tf" {
  name               = "test-lb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id]
  subnets            = [var.public_subnet_1_id, var.public_subnet_2_id]

  tags = {
    Environment = "production"
  }
}

# Security group for the Application Load Balancer
resource "aws_security_group" "lb_sg" {
  name        = "alb-security-group"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "alb-security-group"
  }
}


# Allow HTTP traffic from internet
resource "aws_vpc_security_group_ingress_rule" "lb_http" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
}



# Allow all outbound traffic (ALB needs to forward traffic to targets)
resource "aws_vpc_security_group_egress_rule" "lb_egress" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # -1 means all protocols
}

# Security group for ECS service
resource "aws_security_group" "ecs_service" {
  name        = "ecs-service-sg"
  description = "Security group for ECS service"
  vpc_id      = var.vpc_id

  tags = {
    Name = "ecs-service-sg"
  }
}

# Allow inbound traffic from ALB on port 3000
resource "aws_vpc_security_group_ingress_rule" "ecs_from_alb" {
  security_group_id            = aws_security_group.ecs_service.id
  referenced_security_group_id = aws_security_group.lb_sg.id
  from_port                    = 3000
  ip_protocol                  = "tcp"
  to_port                      = 3000
}

# Allow all outbound traffic from ECS tasks
resource "aws_vpc_security_group_egress_rule" "ecs_egress" {
  security_group_id = aws_security_group.ecs_service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Target group for IP addresses
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

# HTTP Listener
resource "aws_lb_listener" "front_end" {
  load_balancer_arn = aws_lb.test-lb-tf.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.management_api.arn
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


resource "aws_ecs_task_definition" "service" {
  family                   = "service"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 3072
  container_definitions = jsonencode([
    {
      name  = "management-api"
      image = "908860991626.dkr.ecr.us-east-1.amazonaws.com/ragline-backend:latest"
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
          value = "us-east-1" # from user  
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
          value = "users"
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
          "awslogs-group"         = "/ecs/service"
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

# IAM Role for ECS Task (used by the application)
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

# IAM Policy for ECS Task (S3 and DynamoDB permissions)
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
          "s3:PutObjectAcl"
        ]
        Resource = "${aws_s3_bucket.bucket.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query",
          "dynamodb:Scan"
        ]
        Resource = [
          "arn:aws:dynamodb:us-east-1:908860991626:table/documents*",
          "arn:aws:dynamodb:us-east-1:908860991626:table/users*",
        ]
      }
    ]
  })
}

# IAM Role for Ingestion ECS Task
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

# IAM Policy for Ingestion ECS Task
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

# IAM Role for ECS Task Execution (used by ECS to pull images, write logs, retrieve secrets)
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

# Attach AWS managed policy for ECS task execution
resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Attach AWS managed policy for Secrets Manager read access
resource "aws_iam_role_policy_attachment" "ecs_execution_secrets_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}


# CloudWatch Log Group for ECS tasks
resource "aws_cloudwatch_log_group" "ecs_service" {
  name              = "/ecs/service"
  retention_in_days = 7

  tags = {
    Name = "ecs-service-logs"
  }
}

# CloudWatch Log Group for ingestion tasks
resource "aws_cloudwatch_log_group" "ingestion_terraform" {
  name              = "/ecs/ingestion-terraform"
  retention_in_days = 7

  tags = {
    Name = "ingestion-terraform-logs"
  }
}

# Random passwords
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

# Store passwords in Secrets Manager
resource "aws_secretsmanager_secret" "admin-password" {
  name                    = "ragline/admin-password"
  description             = "Admin password for ragline application"
  recovery_window_in_days = 0 # Set to 0 for immediate deletion, or 7-30 for recovery window

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
  task_definition = aws_ecs_task_definition.service.arn
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
  bucket = "rag-pipeline-documents-${lower(random_id.s3-bucket-suffix.id)}"
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
      security_groups  = [aws_security_group.ecs_service.id]
    }
  }

  input_transformer {
    input_paths = {
      detail_bucket_name = "$.detail.bucket.name"
      detail_object_key  = "$.detail.object.key"
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
      image     = "908860991626.dkr.ecr.us-east-1.amazonaws.com/ingest-opensearch:latest"
      essential = true
      portMappings = [
        {
          containerPort = 80
          protocol      = "tcp"
          appProtocol   = "http"
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