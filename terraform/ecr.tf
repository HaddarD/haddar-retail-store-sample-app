# ============================================================================
# ECR Repositories
# Creates repositories for all microservices
# ============================================================================

# ----------------------------------------------------------------------------
# ECR Repositories
# ----------------------------------------------------------------------------
resource "aws_ecr_repository" "services" {
  for_each = toset(var.microservices)

  name                 = "${var.ecr_repo_prefix}-${each.key}"
  image_tag_mutability = var.ecr_image_tag_mutability

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  force_delete = var.ecr_force_delete

  tags = {
    Name        = "${var.ecr_repo_prefix}-${each.key}"
    Service     = each.key
    Environment = var.environment
  }
}

# ----------------------------------------------------------------------------
# Lifecycle Policies (auto-cleanup old images)
# ----------------------------------------------------------------------------
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep last ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "release", "main"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_image_retention_count
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Delete untagged images after ${var.ecr_untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.ecr_untagged_expiry_days
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
