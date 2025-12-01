# ============================================================================
# Terraform Main Configuration
# Kubernetes kubeadm Cluster - Complete Infrastructure
# ============================================================================

# ----------------------------------------------------------------------------
# Terraform Configuration
# ----------------------------------------------------------------------------
terraform {
  required_version = ">= 1.0.0"

  # S3 Backend for remote state storage
  # Comment this out for initial bootstrap run
  backend "s3" {
    bucket         = "haddar-k8s-terraform-state"
    key            = "kubernetes/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}

# ----------------------------------------------------------------------------
# AWS Provider Configuration
# ----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      ManagedBy   = "Terraform"
      Environment = var.environment
      Owner       = "haddar"
    }
  }
}

# ----------------------------------------------------------------------------
# Data Sources
# ----------------------------------------------------------------------------

# Get current AWS account ID
data "aws_caller_identity" "current" {}

# Get latest Ubuntu 24.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# Get available availability zones
data "aws_availability_zones" "available" {
  state = "available"
}
