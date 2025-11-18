Repository: ragline-infrastructure
Prerequisite (input variables) 
# VPC, 2 public subnets, 2 private subnets

start with ALB today! 

ragline-infrastructure/
├── management-api-backend/ # ECS service for ragline management API + Dynamo, security groups
├── ingestion-document-processing/ # ECS task + S3 + EventBridge + IAM, security groups
└── README.md
