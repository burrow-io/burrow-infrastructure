# One of us: make a brand new VPC manually (to meet pre-req)
# - make sure it has 2 public subnets & 2 private subnets)
# The other: figure out how to configure terraform
#  - figure out what account to use and S3 backend (store state in S3 bucket that we make rather than locally)
# Together: make alb, listener, target group
# - be able to: terraform apply, then terraform destroy