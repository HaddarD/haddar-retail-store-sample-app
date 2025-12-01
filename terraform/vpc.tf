# ============================================================================
# VPC Infrastructure
# Creates VPC, Subnet, Internet Gateway, and Route Tables
# ============================================================================

# ----------------------------------------------------------------------------
# VPC
# ----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-vpc"
  }
}

# ----------------------------------------------------------------------------
# Public Subnet
# ----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-public-subnet"
  }
}

# ----------------------------------------------------------------------------
# Internet Gateway
# ----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-igw"
  }
}

# ----------------------------------------------------------------------------
# Route Table
# ----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-public-rt"
  }
}

# ----------------------------------------------------------------------------
# Route Table Association
# ----------------------------------------------------------------------------
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
