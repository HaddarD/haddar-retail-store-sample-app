# ============================================================================
# DynamoDB Table
# Creates table for cart service
# ============================================================================

resource "aws_dynamodb_table" "cart" {
  name         = var.dynamodb_table_name
  billing_mode = var.dynamodb_billing_mode
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name        = var.dynamodb_table_name
    Service     = "cart"
    Environment = var.environment
  }
}
