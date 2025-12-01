# ============================================================================
# Terraform Variables
# All configurable parameters for the infrastructure
# ============================================================================

# ----------------------------------------------------------------------------
# General Configuration
# ----------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "haddar-k8s-kubeadm"
}

variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "haddar"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

# ----------------------------------------------------------------------------
# VPC Configuration
# ----------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

# ----------------------------------------------------------------------------
# EC2 Configuration
# ----------------------------------------------------------------------------

variable "instance_type" {
  description = "EC2 instance type for all nodes"
  type        = string
  default     = "t3.medium"
}

variable "root_volume_size" {
  description = "Root volume size in GB (minimum 20GB for RabbitMQ)"
  type        = number
  default     = 20
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
  default     = "haddar-k8s-kubeadm-key"
}

# ----------------------------------------------------------------------------
# ECR Configuration
# ----------------------------------------------------------------------------

variable "ecr_repo_prefix" {
  description = "Prefix for ECR repository names"
  type        = string
  default     = "haddar-retail-store"
}

variable "ecr_image_tag_mutability" {
  description = "Image tag mutability for ECR repositories"
  type        = string
  default     = "MUTABLE"
}

variable "ecr_scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "ecr_force_delete" {
  description = "Allow deletion of repositories with images"
  type        = bool
  default     = true
}

variable "ecr_image_retention_count" {
  description = "Number of images to retain"
  type        = number
  default     = 30
}

variable "ecr_untagged_expiry_days" {
  description = "Days before untagged images expire"
  type        = number
  default     = 7
}

# ----------------------------------------------------------------------------
# DynamoDB Configuration
# ----------------------------------------------------------------------------

variable "dynamodb_table_name" {
  description = "DynamoDB table name for cart service"
  type        = string
  default     = "haddar-retail-store-cart-table"
}

variable "dynamodb_billing_mode" {
  description = "DynamoDB billing mode"
  type        = string
  default     = "PAY_PER_REQUEST"
}

# ----------------------------------------------------------------------------
# Microservices List
# ----------------------------------------------------------------------------

variable "microservices" {
  description = "List of microservices requiring ECR repositories"
  type        = list(string)
  default = [
    "ui",
    "catalog",
    "cart",
    "orders",
    "checkout"
  ]
}
