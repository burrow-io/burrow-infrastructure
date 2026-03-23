#---------- ALB Security Group ----------

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "lb_sg" {
  name        = "alb-security-group"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name = "alb-security-group"
  }
}

resource "aws_vpc_security_group_ingress_rule" "lb_from_cloudfront" {
  security_group_id = aws_security_group.lb_sg.id
  description       = "Allow CloudFront origin-facing IPs to reach ALB (port 80)"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_ingress_rule" "lb_allow_from_nat" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "${aws_eip.burrow_nat_eip.public_ip}/32"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "Allow NAT gateway public IP to reach ALB - ECS tasks in private subnets"
}

resource "aws_vpc_security_group_egress_rule" "lb_egress" {
  security_group_id = aws_security_group.lb_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

#---------- ECS Service Security Group ----------

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

#---------- Ingestion Task Security Group ----------

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

#---------- Query Service Security Group ----------

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

#---------- Aurora Security Group ----------

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

resource "aws_vpc_security_group_ingress_rule" "tf_aurora_from_query" {
  security_group_id            = aws_security_group.tf_aurora_sg.id
  referenced_security_group_id = aws_security_group.query_service.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "aurora_from_lambda" {
  security_group_id            = aws_security_group.tf_aurora_sg.id
  referenced_security_group_id = aws_security_group.dlq_lambda_sg.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

#---------- DLQ Lambda Security Group ----------

resource "aws_security_group" "dlq_lambda_sg" {
  name   = "dlq-lambda-sg"
  vpc_id = var.vpc_id

  tags = {
    Name = "dlq-lambda-sg"
  }
}

resource "aws_vpc_security_group_egress_rule" "dlq_lambda_egress" {
  security_group_id = aws_security_group.dlq_lambda_sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
