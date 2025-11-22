resource "aws_ecr_repository" "ingestion-terraform-ecr-repo" {
  name                 = "ingestion-terraform-ecr-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "management-terraform-ecr-repo" {
  name                 = "management-terraform-ecr-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "query-api-terraform-ecr-repo" {
  name                 = "query-api-terraform-ecr-repo"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}