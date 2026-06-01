terraform {
  required_version = ">= 1.2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.37"
    }
  }

  backend "s3" {
    bucket         = "aws-load-balancer-terraform-state"
    key            = "terraform.tfstate"
    region         = "il-central-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

