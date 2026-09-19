terraform {
  required_version = ">= 1.5"
  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = "aws-cloudops-lab"
      ManagedBy = "terraform"
    }
  }
}
