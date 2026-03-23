#---------- Random Passwords ----------

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

resource "random_password" "query_api_token" {
  length           = 32
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "tf_aurora_master_password" {
  length           = 20
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "origin_verify_secret" {
  length  = 32
  special = false
}

#---------- Secrets Manager ----------

resource "aws_secretsmanager_secret" "admin-password" {
  name                    = "burrow/admin-password"
  description             = "Admin password for burrow application"
  recovery_window_in_days = 0

  tags = {
    Name = "burrow-admin-password"
  }
}

resource "aws_secretsmanager_secret_version" "admin-password" {
  secret_id     = aws_secretsmanager_secret.admin-password.id
  secret_string = random_password.admin-password.result
}

resource "aws_secretsmanager_secret" "jwt-secret" {
  name                    = "burrow/jwt-secret"
  description             = "JWT secret key for burrow application"
  recovery_window_in_days = 0

  tags = {
    Name = "burrow-jwt-secret"
  }
}

resource "aws_secretsmanager_secret_version" "jwt-secret" {
  secret_id     = aws_secretsmanager_secret.jwt-secret.id
  secret_string = random_password.jwt-secret.result
}

resource "aws_secretsmanager_secret" "ingestion-api-token" {
  name                    = "burrow/ingestion-api-token"
  description             = "API token for ingestion service"
  recovery_window_in_days = 0

  tags = {
    Name = "burrow-ingestion-api-token"
  }
}

resource "aws_secretsmanager_secret_version" "ingestion-api-token" {
  secret_id     = aws_secretsmanager_secret.ingestion-api-token.id
  secret_string = random_password.ingestion-api-token.result
}

resource "aws_secretsmanager_secret" "query_api_token" {
  name                    = "burrow/query-api-token"
  description             = "API token for query-service"
  recovery_window_in_days = 0

  tags = {
    Name = "burrow-query-api-token"
  }
}

resource "aws_secretsmanager_secret_version" "query_api_token" {
  secret_id     = aws_secretsmanager_secret.query_api_token.id
  secret_string = random_password.query_api_token.result
}

resource "aws_secretsmanager_secret" "aurora_db_password" {
  name                    = "burrow/aurora-db-password"
  description             = "Aurora DB password for burrowdb"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "aurora_db_password" {
  secret_id     = aws_secretsmanager_secret.aurora_db_password.id
  secret_string = random_password.tf_aurora_master_password.result
}

resource "aws_secretsmanager_secret" "origin_verify" {
  name                    = "burrow/origin-verify"
  description             = "Shared X-Origin-Verify header secret for CloudFront + internal services"
  recovery_window_in_days = 0

  tags = {
    Name = "burrow-origin-verify"
  }
}

resource "aws_secretsmanager_secret_version" "origin_verify" {
  secret_id     = aws_secretsmanager_secret.origin_verify.id
  secret_string = random_password.origin_verify_secret.result
}
