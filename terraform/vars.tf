variable "public_subnet_1_id" {
  description = "ID of the az1 public subnet"
  type        = string
}

variable "public_subnet_2_id" {
  description = "ID of the az2 public subnet"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC"
  type        = string
}

variable "private_subnet_1_id" {
  description = "ID of the az1 private subnet"
  type        = string
}

variable "private_subnet_2_id" {
  description = "ID of the az2 private subnet"
  type        = string
}

variable "region" {
  description = "AWS region for resources"
  type        = string
}
