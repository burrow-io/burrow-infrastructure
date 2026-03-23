output "admin-password" {
  description = "Admin password for burrow application"
  value       = random_password.admin-password.result
  sensitive   = true
}

output "rag-api-token" {
  description = "API token for query service"
  value       = random_password.query_api_token.result
  sensitive   = true
}

output "cloudfront-dns-record" {
  description = "DNS record for Cloudfront"
  value       = aws_cloudfront_distribution.burrow.domain_name
}

output "front-end-bucket" {
  description = "Bucket for the UI"
  value       = aws_s3_bucket.frontend.bucket
}
