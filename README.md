# Burrow Infrastructure

Terraform configuration for deploying the Burrow infrastructure on AWS, including ECS services, load balancer, DynamoDB tables, RDS Aurora cluster, and supporting resources.

## Prerequisites

- Terraform >= 1.0
- AWS CLI configured with appropriate credentials
- Existing VPC with 2 public subnets and 2 private subnets

## Setup

1. Configure your variables in `terraform/terraform.tfvars`:

   ```hcl
   vpc_id              = "vpc-xxxxx"
   public_subnet_1_id  = "subnet-xxxxx"
   public_subnet_2_id  = "subnet-xxxxx"
   private_subnet_1_id = "subnet-xxxxx"
   private_subnet_2_id = "subnet-xxxxx"
   ```

2. Navigate to the terraform directory:

   ```bash
   cd terraform
   ```

3. Initialize Terraform:

   ```bash
   terraform init
   ```

4. Review the execution plan:

   ```bash
   terraform plan
   ```

5. Apply the configuration:
   ```bash
   terraform apply
   ```

## Destroy

To tear down all resources:

```bash
cd terraform
terraform destroy
```

## Backend

State is stored in S3: `burrow-terraform-state-us-east-1-12345/burrow/terraform-main.tfstate`
