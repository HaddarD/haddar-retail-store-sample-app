# ============================================================================
# Terraform Variable Values
# haddar's Kubernetes kubeadm Cluster Configuration
# ============================================================================

# General Configuration
aws_region   = "us-east-1"
project_name = "haddar-k8s-kubeadm"
name_prefix  = "haddar"
environment  = "dev"

# VPC Configuration
vpc_cidr           = "10.0.0.0/16"
public_subnet_cidr = "10.0.1.0/24"

# EC2 Configuration
instance_type      = "t3.medium"
root_volume_size   = 20  # Minimum for RabbitMQ
key_name           = "haddar-k8s-kubeadm-key"

# ECR Configuration
ecr_repo_prefix            = "haddar-retail-store"
ecr_image_tag_mutability   = "MUTABLE"
ecr_scan_on_push           = true
ecr_force_delete           = true
ecr_image_retention_count  = 30
ecr_untagged_expiry_days   = 7

# DynamoDB Configuration
dynamodb_table_name   = "haddar-retail-store-cart-table"
dynamodb_billing_mode = "PAY_PER_REQUEST"

# Microservices
microservices = [
  "ui",
  "catalog",
  "cart",
  "orders",
  "checkout"
]
