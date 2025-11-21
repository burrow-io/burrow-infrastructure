terraform {
  required_version = ">= 1.0"

  backend "s3" {
    bucket  = "burrow-terraform-state-us-east-1-12345"
    key     = "burrow/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

