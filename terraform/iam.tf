# ============================================================================
# IAM Role and Instance Profile
# Provides EC2 instances with ECR and DynamoDB access
# ============================================================================

# ----------------------------------------------------------------------------
# IAM Role for EC2 Instances
# ----------------------------------------------------------------------------
resource "aws_iam_role" "ecr_access" {
  name = "${var.name_prefix}-k8s-kubeadm-ecr-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-ecr-role"
  }
}

# ----------------------------------------------------------------------------
# IAM Policy for ECR Access
# ----------------------------------------------------------------------------
resource "aws_iam_role_policy" "ecr_access" {
  name = "ECRAccessPolicy"
  role = aws_iam_role.ecr_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:DescribeRepositories",
          "ecr:ListImages"
        ]
        Resource = "*"
      }
    ]
  })
}

# ----------------------------------------------------------------------------
# IAM Policy for DynamoDB Access
# ----------------------------------------------------------------------------
resource "aws_iam_role_policy" "dynamodb_access" {
  name = "DynamoDBAccessPolicy"
  role = aws_iam_role.ecr_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:BatchGetItem",
          "dynamodb:BatchWriteItem",
          "dynamodb:DeleteItem",
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:UpdateItem",
          "dynamodb:DescribeTable"
        ]
        Resource = aws_dynamodb_table.cart.arn
      }
    ]
  })
}

# ----------------------------------------------------------------------------
# IAM Instance Profile
# ----------------------------------------------------------------------------
resource "aws_iam_instance_profile" "ecr_access" {
  name = "${var.name_prefix}-k8s-kubeadm-ecr-profile"
  role = aws_iam_role.ecr_access.name

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-ecr-profile"
  }
}
