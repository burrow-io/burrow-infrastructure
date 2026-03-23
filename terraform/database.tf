#---------- DynamoDB Tables ----------

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

  ttl {
    enabled        = true
    attribute_name = "purgeAt"
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

#---------- Aurora PostgreSQL ----------

resource "aws_db_subnet_group" "tf_aurora_subnets" {
  name       = "tf-aurora-private-subnets"
  subnet_ids = [var.private_subnet_1_id, var.private_subnet_2_id]

  tags = {
    Name = "tf-aurora-private-subnets"
  }
}

resource "aws_rds_cluster" "tf_aurora_pg" {
  cluster_identifier  = "burrow-aurora-tf"
  engine              = "aurora-postgresql"
  engine_version      = "17.4"
  engine_mode         = "provisioned"
  database_name       = "burrowdb"
  master_username     = "burrow_admin"
  master_password     = random_password.tf_aurora_master_password.result
  storage_encrypted   = true
  skip_final_snapshot = true

  db_subnet_group_name   = aws_db_subnet_group.tf_aurora_subnets.name
  vpc_security_group_ids = [aws_security_group.tf_aurora_sg.id]

  serverlessv2_scaling_configuration {
    min_capacity             = 0
    max_capacity             = 8
    seconds_until_auto_pause = 300
  }

  tags = {
    Name = "burrow-aurora-tf"
  }
}

resource "aws_rds_cluster_instance" "tf_aurora_pg_instance" {
  identifier         = "burrow-aurora-tf-1"
  cluster_identifier = aws_rds_cluster.tf_aurora_pg.id

  instance_class = "db.serverless"
  engine         = aws_rds_cluster.tf_aurora_pg.engine
  engine_version = aws_rds_cluster.tf_aurora_pg.engine_version

  publicly_accessible = false

  monitoring_interval          = 0
  performance_insights_enabled = false

  tags = {
    Name = "burrow-aurora-tf-1"
  }
}
