#---------- Internet Gateway & NAT ----------

resource "aws_internet_gateway" "burrow_igw" {
  vpc_id = var.vpc_id
  tags = {
    Name = "burrow-igw"
  }
}

resource "aws_eip" "burrow_nat_eip" {
  domain = "vpc"
  tags = {
    Name = "burrow-nat-eip"
  }
}

resource "aws_nat_gateway" "burrow_nat" {
  allocation_id = aws_eip.burrow_nat_eip.id
  subnet_id     = var.public_subnet_1_id
  tags = {
    Name = "burrow-nat-gateway"
  }
}

#---------- Route Tables ----------

resource "aws_route_table" "burrow_public_rt" {
  vpc_id = var.vpc_id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.burrow_igw.id
  }
  tags = {
    Name = "burrow-public-rt"
  }
}

resource "aws_route_table" "burrow_private_rt" {
  vpc_id = var.vpc_id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.burrow_nat.id
  }
  tags = {
    Name = "burrow-private-rt"
  }
}

resource "aws_route_table_association" "public_subnet_1" {
  subnet_id      = var.public_subnet_1_id
  route_table_id = aws_route_table.burrow_public_rt.id
}

resource "aws_route_table_association" "public_subnet_2" {
  subnet_id      = var.public_subnet_2_id
  route_table_id = aws_route_table.burrow_public_rt.id
}

resource "aws_route_table_association" "private_subnet_1" {
  subnet_id      = var.private_subnet_1_id
  route_table_id = aws_route_table.burrow_private_rt.id
}

resource "aws_route_table_association" "private_subnet_2" {
  subnet_id      = var.private_subnet_2_id
  route_table_id = aws_route_table.burrow_private_rt.id
}

#---------- Application Load Balancer ----------

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

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify_secret.result]
    }
  }
}

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

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values           = [random_password.origin_verify_secret.result]
    }
  }
}

resource "aws_lb_listener_rule" "management_api_reject" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 6

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/api/*"]
    }
  }
}

resource "aws_lb_listener_rule" "query_api_reject" {
  listener_arn = aws_lb_listener.front_end.arn
  priority     = 11

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  condition {
    path_pattern {
      values = ["/query-service/*"]
    }
  }
}
