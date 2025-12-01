

# # Dummy resource for testing
# resource "aws_s3_bucket" "test" {
#   bucket = var.state_bucket
# }

# Generate random API token
resource "random_password" "api_token" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# Store API token in AWS Secrets Manager
resource "aws_secretsmanager_secret" "api_token" {
  name                    = "from-cli/cli-api-token"
  description             = "API token for testing"
  recovery_window_in_days = 0

  tags = {
    Name = "ragline-api-token"
  }
}

# Store the token value in the secret
resource "aws_secretsmanager_secret_version" "api_token" {
  secret_id     = aws_secretsmanager_secret.api_token.id
  secret_string = random_password.api_token.result
}

# Output the API token value
output "api_token" {
  description = "The generated API token value"
  value       = random_password.api_token.result
  sensitive   = true
}

