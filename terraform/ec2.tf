# ============================================================================
# EC2 Instances
# Creates 3 instances: 1 master + 2 workers
# ============================================================================

# ----------------------------------------------------------------------------
# SSH Key Pair
# ----------------------------------------------------------------------------
resource "aws_key_pair" "k8s" {
  key_name   = var.key_name
  public_key = file("../${var.key_name}.pub")

  tags = {
    Name = var.key_name
  }
}

# ----------------------------------------------------------------------------
# Master Node
# ----------------------------------------------------------------------------
resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k8s.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.ecr_access.name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              
              # Update hostname
              hostnamectl set-hostname ${var.name_prefix}-k8s-master
              echo "127.0.0.1 ${var.name_prefix}-k8s-master" >> /etc/hosts
              
              # Update system
              apt-get update
              apt-get upgrade -y
              
              # Install basic tools
              apt-get install -y curl wget vim git jq
              
              echo "Master node initialization complete"
              EOF

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-master"
    Role = "master"
  }

  depends_on = [aws_internet_gateway.main]
}

# ----------------------------------------------------------------------------
# Worker Node 1
# ----------------------------------------------------------------------------
resource "aws_instance" "worker1" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k8s.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.ecr_access.name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              
              # Update hostname
              hostnamectl set-hostname ${var.name_prefix}-k8s-worker1
              echo "127.0.0.1 ${var.name_prefix}-k8s-worker1" >> /etc/hosts
              
              # Update system
              apt-get update
              apt-get upgrade -y
              
              # Install basic tools
              apt-get install -y curl wget vim git jq
              
              echo "Worker1 initialization complete"
              EOF

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-worker1"
    Role = "worker"
  }

  depends_on = [aws_internet_gateway.main]
}

# ----------------------------------------------------------------------------
# Worker Node 2
# ----------------------------------------------------------------------------
resource "aws_instance" "worker2" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.k8s.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.k8s_nodes.id]
  iam_instance_profile   = aws_iam_instance_profile.ecr_access.name

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e
              
              # Update hostname
              hostnamectl set-hostname ${var.name_prefix}-k8s-worker2
              echo "127.0.0.1 ${var.name_prefix}-k8s-worker2" >> /etc/hosts
              
              # Update system
              apt-get update
              apt-get upgrade -y
              
              # Install basic tools
              apt-get install -y curl wget vim git jq
              
              echo "Worker2 initialization complete"
              EOF

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-worker2"
    Role = "worker"
  }

  depends_on = [aws_internet_gateway.main]
}
