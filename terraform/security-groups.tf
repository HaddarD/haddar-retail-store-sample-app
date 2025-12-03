# ============================================================================
# Security Groups
# All ports required for Kubernetes kubeadm cluster
# ============================================================================

resource "aws_security_group" "k8s_nodes" {
  name        = "${var.name_prefix}-k8s-kubeadm-sg"
  description = "Security group for Kubernetes kubeadm cluster nodes"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-k8s-kubeadm-sg"
  }
}

# ----------------------------------------------------------------------------
# SSH Access
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "ssh" {
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "SSH access"
}

# ----------------------------------------------------------------------------
# Kubernetes API Server
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "k8s_api" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "Kubernetes API server"
}

# ----------------------------------------------------------------------------
# etcd Server Client API
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "etcd" {
  type                     = "ingress"
  from_port                = 2379
  to_port                  = 2380
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "etcd server client API"
}

# ----------------------------------------------------------------------------
# Kubelet API
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "kubelet" {
  type                     = "ingress"
  from_port                = 10250
  to_port                  = 10250
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "Kubelet API"
}

# ----------------------------------------------------------------------------
# kube-scheduler
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "kube_scheduler" {
  type                     = "ingress"
  from_port                = 10259
  to_port                  = 10259
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "kube-scheduler"
}

# ----------------------------------------------------------------------------
# kube-controller-manager
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "kube_controller" {
  type                     = "ingress"
  from_port                = 10257
  to_port                  = 10257
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "kube-controller-manager"
}

# ----------------------------------------------------------------------------
# NodePort Services
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "nodeport" {
  type              = "ingress"
  from_port         = 30000
  to_port           = 32767
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "NodePort Services"
}

# ----------------------------------------------------------------------------
# Calico BGP
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "calico_bgp" {
  type                     = "ingress"
  from_port                = 179
  to_port                  = 179
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "Calico BGP"
}

# ----------------------------------------------------------------------------
# Calico IP-in-IP
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "calico_ipip" {
  type                     = "ingress"
  from_port                = -1
  to_port                  = -1
  protocol                 = 4
  source_security_group_id = aws_security_group.k8s_nodes.id
  security_group_id        = aws_security_group.k8s_nodes.id
  description              = "Calico IP-in-IP (Protocol 4)"
}

# ----------------------------------------------------------------------------
# HTTP/HTTPS for application access
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "http" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "HTTP"
}

resource "aws_security_group_rule" "https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "HTTPS"
}

# ----------------------------------------------------------------------------
# Egress - Allow all outbound traffic
# ----------------------------------------------------------------------------
resource "aws_security_group_rule" "egress_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.k8s_nodes.id
  description       = "Allow all outbound traffic"
}
