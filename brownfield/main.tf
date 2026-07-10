terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# A resource created by hand (see brownfield/README.md), then brought under
# Terraform management via `terraform import` and reconciled to this config.
resource "aws_s3_bucket" "brownfield" {
  bucket = "cops-brownfield-638515252275"
  tags = {
    Environment = "lab"
    ManagedBy   = "terraform"
  }
}
