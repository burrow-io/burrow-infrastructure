Repository: ragline-infrastructure
Prerequisite (input variables) 
# VPC, 2 public subnets, 2 private subnets

start with ALB today! 

ragline-infrastructure/
├── management-api-backend/ # ECS service for your ragline API + Dynamo, security groups
├── ingestion-document-processing/ # ECS task + S3 + EventBridge + IAM, security groups
└── README.md

Key Components for Your Pipeline:

modules/api-backend/:
- ECS service for your current ragline API
- ALB, target groups, security groups
- Auto-scaling policies





Key Components for Your Pipeline:

modules/api-backend/:
- ECS service for your current ragline API
- ALB, target groups, security groups
- Auto-scaling policies



# Later:

├── shared/
│ ├── ecr.tf # ECR repos for both services
│ ├── ssm.tf # API tokens, secrets
│ └── iam.tf # Cross-service IAM roles
├── scripts/
│ ├── generate-api-token.sh
│ ├── deploy.sh
│ └── rotate-token.sh


shared/ssm.tf:
resource "aws_ssm_parameter" "api_token" {
name = "/ragline/processing/api-token"
type = "SecureString"
value = random_password.api_token.result
}

resource "random_password" "api_token" {
length = 64
special = false
}