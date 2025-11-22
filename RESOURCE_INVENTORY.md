# Terraform Resource Inventory

## Input Variables

All variables are defined in `vars.tf` and must be provided via `terraform.tfvars`:

- `vpc_id` - ID of the VPC
- `public_subnet_1_id` - ID of the AZ1 public subnet
- `public_subnet_2_id` - ID of the AZ2 public subnet
- `private_subnet_1_id` - ID of the AZ1 private subnet
- `private_subnet_2_id` - ID of the AZ2 private subnet

---

## 1. LOAD BALANCER & NETWORKING

### Application Load Balancer

- **Resource**: `aws_lb.test-lb-tf`
  - **Name**: `test-lb-tf`
  - **Type**: Application Load Balancer
  - **Dependencies**:
    - `aws_security_group.lb_sg`
    - `var.public_subnet_1_id`
    - `var.public_subnet_2_id`

### Load Balancer Listener

- **Resource**: `aws_lb_listener.front_end`
  - **Port**: 80 (HTTP)
  - **Dependencies**:
    - `aws_lb.test-lb-tf`
    - `aws_lb_target_group.management_api`

### Target Group

- **Resource**: `aws_lb_target_group.management_api`
  - **Name**: `alb-target-group`
  - **Port**: 3000
  - **Protocol**: HTTP
  - **Health Check**: `/health` endpoint
  - **Dependencies**:
    - `var.vpc_id`

### Security Groups

#### Load Balancer Security Group

- **Resource**: `aws_security_group.lb_sg`
  - **Name**: `alb-security-group`
  - **Dependencies**: `var.vpc_id`
  - **Associated Rules**:
    - `aws_vpc_security_group_ingress_rule.lb_http` (Port 80 from 0.0.0.0/0)
    - `aws_vpc_security_group_egress_rule.lb_egress` (All outbound)

#### ECS Service Security Group

- **Resource**: `aws_security_group.ecs_service`
  - **Name**: `ecs-service-sg`
  - **Dependencies**: `var.vpc_id`
  - **Associated Rules**:
    - `aws_vpc_security_group_ingress_rule.ecs_from_alb` (Port 3000 from ALB)
    - `aws_vpc_security_group_egress_rule.ecs_egress` (All outbound)

---

## 2. ECS CLUSTER & SERVICES

### ECS Cluster

- **Resource**: `aws_ecs_cluster.management-api-cluster`
  - **Name**: `burrow-cluster`
  - **Features**: Container Insights enabled

### ECS Task Definitions

#### Management API Task Definition

- **Resource**: `aws_ecs_task_definition.service`
  - **Family**: `service`
  - **Platform**: Fargate
  - **CPU**: 1024
  - **Memory**: 3072 MB
  - **Architecture**: ARM64
  - **Container**: `management-api`
  - **Image**: `908860991626.dkr.ecr.us-east-1.amazonaws.com/ragline-backend:latest`
  - **Port**: 3000
  - **Dependencies**:
    - `aws_iam_role.ecs_task_role`
    - `aws_iam_role.ecs_execution_role`
    - `aws_s3_bucket.bucket`
    - `aws_secretsmanager_secret.admin-password`
    - `aws_secretsmanager_secret.jwt-secret`
    - `aws_secretsmanager_secret.ingestion-api-token`
    - `aws_cloudwatch_log_group.ecs_service`

#### Ingestion Task Definition

- **Resource**: `aws_ecs_task_definition.ingestion-terraform`
  - **Family**: `ingestion-terraform`
  - **Platform**: Fargate
  - **CPU**: 2048
  - **Memory**: 5120 MB
  - **Architecture**: ARM64
  - **Container**: `ingestion-container`
  - **Image**: `908860991626.dkr.ecr.us-east-1.amazonaws.com/ingest-opensearch:latest`
  - **Port**: 80
  - **Dependencies**:
    - `aws_iam_role.ingestion_task_role`
    - `aws_iam_role.ecs_execution_role`
    - `aws_cloudwatch_log_group.ingestion_terraform`

### ECS Service

- **Resource**: `aws_ecs_service.management-api-service`
  - **Name**: `management-api-service`
  - **Cluster**: `burrow-cluster`
  - **Desired Count**: 1
  - **Dependencies**:
    - `aws_ecs_cluster.management-api-cluster`
    - `aws_ecs_task_definition.service`
    - `aws_lb_target_group.management_api`
    - `aws_security_group.ecs_service`
    - `var.private_subnet_1_id`
    - `var.private_subnet_2_id`

---

## 3. IAM ROLES & POLICIES

### ECS Task Roles

#### Management API Task Role

- **Resource**: `aws_iam_role.ecs_task_role`
  - **Name**: `ecs-task-role`
  - **Service**: `ecs-tasks.amazonaws.com`
  - **Associated Policy**: `aws_iam_role_policy.ecs_task_policy`
    - S3: PutObject, PutObjectAcl (on bucket)
    - DynamoDB: GetItem, PutItem, UpdateItem, Query, Scan (on documents* and users* tables)

#### Ingestion Task Role

- **Resource**: `aws_iam_role.ingestion_task_role`
  - **Name**: `ingestion-task-role`
  - **Service**: `ecs-tasks.amazonaws.com`
  - **Associated Policy**: `aws_iam_role_policy.ingestion_task_policy`
    - S3: GetObject, ListBucket
    - Secrets Manager: GetSecretValue, DescribeSecret
    - Bedrock: InvokeModel, InvokeModelWithResponseStream

### ECS Execution Role

- **Resource**: `aws_iam_role.ecs_execution_role`
  - **Name**: `ecs-execution-role`
  - **Service**: `ecs-tasks.amazonaws.com`
  - **Used By**: Both task definitions
  - **Attached Policies**:
    - `aws_iam_role_policy_attachment.ecs_execution_role_policy` (AmazonECSTaskExecutionRolePolicy)
    - `aws_iam_role_policy_attachment.ecs_execution_secrets_policy` (SecretsManagerReadWrite)

### EventBridge Role

- **Resource**: `aws_iam_role.eventbridge_ecs_role`
  - **Name**: `eventbridge-ecs-role`
  - **Service**: `events.amazonaws.com`
  - **Associated Policy**: `aws_iam_role_policy.eventbridge_ecs_policy`
    - ECS: RunTask (all resources)
    - IAM: PassRole (all resources, condition: passed to ecs-tasks.amazonaws.com)

---

## 4. S3 & EVENTBRIDGE

### S3 Bucket

- **Resource**: `aws_s3_bucket.bucket`
  - **Name**: `rag-pipeline-documents-{random_suffix}`
  - **Dependencies**:
    - `random_id.s3-bucket-suffix`

### S3 Bucket Notification

- **Resource**: `aws_s3_bucket_notification.bucket_notification`
  - **EventBridge**: Enabled
  - **Dependencies**: `aws_s3_bucket.bucket`

### EventBridge Rule

- **Resource**: `aws_cloudwatch_event_rule.s3_object_created_rule`
  - **Name**: `s3-object-created-rule`
  - **Event Pattern**: S3 Object Created events
  - **Dependencies**: `aws_s3_bucket.bucket`

### EventBridge Target

- **Resource**: `aws_cloudwatch_event_target.ecs_task_target`
  - **Target ID**: `TriggerECSTask`
  - **Dependencies**:
    - `aws_cloudwatch_event_rule.s3_object_created_rule`
    - `aws_ecs_cluster.management-api-cluster`
    - `aws_ecs_task_definition.ingestion-terraform`
    - `aws_iam_role.eventbridge_ecs_role`
    - `aws_security_group.ecs_service`
    - `var.private_subnet_1_id`
    - `var.private_subnet_2_id`
  - **Input Transformer**: Passes S3_BUCKET_NAME and S3_OBJECT_KEY as environment variables

---

## 5. DYNAMODB TABLES

### Documents Table

- **Resource**: `aws_dynamodb_table.documents-table`
  - **Name**: `documents-terraform`
  - **Billing**: PAY_PER_REQUEST
  - **Hash Key**: `documentId`
  - **GSI**: `status-createdAt-index` (hash: status, range: createdAt)

### Users Table

- **Resource**: `aws_dynamodb_table.users-table`
  - **Name**: `users-terraform`
  - **Billing**: PAY_PER_REQUEST
  - **Hash Key**: `userName`

---

## 6. SECRETS MANAGER

### Secrets

#### Admin Password

- **Resource**: `aws_secretsmanager_secret.admin-password`
  - **Name**: `ragline/admin-password`
- **Secret Version**: `aws_secretsmanager_secret_version.admin-password`
  - **Dependencies**:
    - `aws_secretsmanager_secret.admin-password`
    - `random_password.admin-password`

#### JWT Secret

- **Resource**: `aws_secretsmanager_secret.jwt-secret`
  - **Name**: `ragline/jwt-secret`
- **Secret Version**: `aws_secretsmanager_secret_version.jwt-secret`
  - **Dependencies**:
    - `aws_secretsmanager_secret.jwt-secret`
    - `random_password.jwt-secret`

#### Ingestion API Token

- **Resource**: `aws_secretsmanager_secret.ingestion-api-token`
  - **Name**: `ragline/ingestion-api-token`
- **Secret Version**: `aws_secretsmanager_secret_version.ingestion-api-token`
  - **Dependencies**:
    - `aws_secretsmanager_secret.ingestion-api-token`
    - `random_password.ingestion-api-token`

### Random Passwords

- **Resources**:
  - `random_password.admin-password`
  - `random_password.jwt-secret`
  - `random_password.ingestion-api-token`

---

## 7. CLOUDWATCH LOGS

### Log Groups

- **Resource**: `aws_cloudwatch_log_group.ecs_service`

  - **Name**: `/ecs/service`
  - **Retention**: 7 days
  - **Used By**: `aws_ecs_task_definition.service`

- **Resource**: `aws_cloudwatch_log_group.ingestion_terraform`
  - **Name**: `/ecs/ingestion-terraform`
  - **Retention**: 7 days
  - **Used By**: `aws_ecs_task_definition.ingestion-terraform`

---

## 8. UTILITY RESOURCES

### Random ID

- **Resource**: `random_id.s3-bucket-suffix`
  - **Purpose**: Generate unique suffix for S3 bucket name
  - **Byte Length**: 4
  - **Used By**: `aws_s3_bucket.bucket`

---

## Resource Dependency Flow

```
VPC (External) → Subnets (External)
    ↓
Load Balancer → Security Groups → ECS Service
    ↓
ECS Cluster → Task Definitions → IAM Roles
    ↓
S3 Bucket → EventBridge Rule → EventBridge Target → ECS Task (Ingestion)
    ↓
DynamoDB Tables (used by ECS tasks)
    ↓
Secrets Manager (used by ECS tasks)
    ↓
CloudWatch Logs (used by ECS tasks)
```

---

## Resource Count Summary

- **Load Balancer**: 1 (ALB + Listener + Target Group)
- **Security Groups**: 2 (LB + ECS) + 4 rules
- **ECS**: 1 cluster, 2 task definitions, 1 service
- **IAM**: 4 roles, 3 policies, 2 policy attachments
- **S3**: 1 bucket + 1 notification
- **EventBridge**: 1 rule + 1 target
- **DynamoDB**: 2 tables
- **Secrets Manager**: 3 secrets + 3 versions
- **CloudWatch**: 2 log groups
- **Random**: 4 resources (3 passwords + 1 ID)

**Total Resources**: ~35 resources
