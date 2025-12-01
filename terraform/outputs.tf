# ============================================================================
# Terraform Outputs
# Export all values needed by deployment scripts
# ============================================================================

# ----------------------------------------------------------------------------
# General Information
# ----------------------------------------------------------------------------

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = data.aws_caller_identity.current.account_id
}

output "project_name" {
  description = "Project name"
  value       = var.project_name
}

# ----------------------------------------------------------------------------
# VPC Outputs
# ----------------------------------------------------------------------------

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}

output "internet_gateway_id" {
  description = "Internet Gateway ID"
  value       = aws_internet_gateway.main.id
}

# ----------------------------------------------------------------------------
# Security Group Outputs
# ----------------------------------------------------------------------------

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.k8s_nodes.id
}

output "security_group_name" {
  description = "Security group name"
  value       = aws_security_group.k8s_nodes.name
}

# ----------------------------------------------------------------------------
# IAM Outputs
# ----------------------------------------------------------------------------

output "iam_role_name" {
  description = "IAM role name"
  value       = aws_iam_role.ecr_access.name
}

output "iam_role_arn" {
  description = "IAM role ARN"
  value       = aws_iam_role.ecr_access.arn
}

output "iam_instance_profile_name" {
  description = "IAM instance profile name"
  value       = aws_iam_instance_profile.ecr_access.name
}

# ----------------------------------------------------------------------------
# EC2 Instance Outputs
# ----------------------------------------------------------------------------

# Master Node
output "master_instance_id" {
  description = "Master node instance ID"
  value       = aws_instance.master.id
}

output "master_public_ip" {
  description = "Master node public IP"
  value       = aws_instance.master.public_ip
}

output "master_private_ip" {
  description = "Master node private IP"
  value       = aws_instance.master.private_ip
}

# Worker Node 1
output "worker1_instance_id" {
  description = "Worker1 instance ID"
  value       = aws_instance.worker1.id
}

output "worker1_public_ip" {
  description = "Worker1 public IP"
  value       = aws_instance.worker1.public_ip
}

output "worker1_private_ip" {
  description = "Worker1 private IP"
  value       = aws_instance.worker1.private_ip
}

# Worker Node 2
output "worker2_instance_id" {
  description = "Worker2 instance ID"
  value       = aws_instance.worker2.id
}

output "worker2_public_ip" {
  description = "Worker2 public IP"
  value       = aws_instance.worker2.public_ip
}

output "worker2_private_ip" {
  description = "Worker2 private IP"
  value       = aws_instance.worker2.private_ip
}

# SSH Key
output "key_name" {
  description = "SSH key pair name"
  value       = aws_key_pair.k8s.key_name
}

output "key_file" {
  description = "SSH private key file path"
  value       = var.key_name
}

# ----------------------------------------------------------------------------
# ECR Outputs
# ----------------------------------------------------------------------------

output "ecr_registry_url" {
  description = "ECR registry URL"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "ecr_repository_urls" {
  description = "Map of ECR repository URLs"
  value = {
    for service in var.microservices :
    service => aws_ecr_repository.services[service].repository_url
  }
}

output "ecr_repository_arns" {
  description = "Map of ECR repository ARNs"
  value = {
    for service in var.microservices :
    service => aws_ecr_repository.services[service].arn
  }
}

# Individual repository URLs for easy access
output "ecr_ui_repo" {
  description = "UI repository URL"
  value       = aws_ecr_repository.services["ui"].repository_url
}

output "ecr_catalog_repo" {
  description = "Catalog repository URL"
  value       = aws_ecr_repository.services["catalog"].repository_url
}

output "ecr_cart_repo" {
  description = "Cart repository URL"
  value       = aws_ecr_repository.services["cart"].repository_url
}

output "ecr_orders_repo" {
  description = "Orders repository URL"
  value       = aws_ecr_repository.services["orders"].repository_url
}

output "ecr_checkout_repo" {
  description = "Checkout repository URL"
  value       = aws_ecr_repository.services["checkout"].repository_url
}

# ----------------------------------------------------------------------------
# DynamoDB Outputs
# ----------------------------------------------------------------------------

output "dynamodb_table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.cart.name
}

output "dynamodb_table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.cart.arn
}

# ----------------------------------------------------------------------------
# Summary Output (formatted for easy reading)
# ----------------------------------------------------------------------------

output "deployment_summary" {
  description = "Complete deployment information"
  value = {
    region             = var.aws_region
    account_id         = data.aws_caller_identity.current.account_id
    vpc_id             = aws_vpc.main.id
    master_public_ip   = aws_instance.master.public_ip
    worker1_public_ip  = aws_instance.worker1.public_ip
    worker2_public_ip  = aws_instance.worker2.public_ip
    ecr_registry       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    dynamodb_table     = aws_dynamodb_table.cart.name
    key_file           = "${var.key_name}.pem"
  }
}
