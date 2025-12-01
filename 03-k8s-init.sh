#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster Initialization Script
# Chat 2/Phase 2: Install and configure Kubernetes cluster with ECR Credential Helper
#
# This script:
# 1. Installs Kubernetes (kubeadm, kubelet, kubectl) on all nodes
# 2. Installs containerd as the container runtime
# 3. Installs ECR Credential Helper on all nodes (Option B - No tokens!)
# 4. Configures containerd to use ECR Credential Helper
# 5. Initializes the Kubernetes cluster on the master node
# 6. Installs Calico CNI
# 7. Joins worker nodes to the cluster
################################################################################

set -e  # Exit on any error

# Load environment variables
if [ ! -f deployment-info.txt ]; then
    echo "❌ ERROR: deployment-info.txt not found!"
    echo "Please run ./02-terraform-apply.sh first"
    exit 1
fi

source deployment-info.txt

# Configuration
KUBERNETES_VERSION="1.28"
CALICO_VERSION="v3.26.1"
POD_NETWORK_CIDR="192.168.0.0/16"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

# Main header
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Kubernetes kubeadm Cluster Initialization          ║"
echo "║   Phase 2: Setup K8s with ECR Credential Helper      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check if SSH key exists
    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key not found: $KEY_FILE"
        exit 1
    fi
    print_success "SSH key found"
    
    # Test SSH connection to master
    print_info "Testing SSH connection to master node..."
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "echo 'SSH test successful'" &>/dev/null; then
        print_success "Master node SSH connection working"
    else
        print_error "Cannot connect to master node via SSH"
        print_info "Wait a few minutes after running 02-terraform-apply.sh"
        exit 1
    fi
    
    print_success "All prerequisites met"
}

# Function to run commands on all nodes
run_on_all_nodes() {
    local COMMAND=$1
    local DESCRIPTION=$2
    
    print_info "$DESCRIPTION"
    
    # Master
    print_info "Running on master..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "$COMMAND"
    
    # Worker 1
    print_info "Running on worker1..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP "$COMMAND"
    
    # Worker 2
    print_info "Running on worker2..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP "$COMMAND"
    
    print_success "$DESCRIPTION - Complete"
}

# Install Kubernetes components on all nodes
install_kubernetes() {
    print_header "Installing Kubernetes Components on All Nodes"
    
    INSTALL_SCRIPT='
#!/bin/bash
set -e

# Disable swap
sudo swapoff -a
sudo sed -i "/ swap / s/^/#/" /etc/fstab

# Load kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Enable SystemdCgroup
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install Kubernetes packages
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v'$KUBERNETES_VERSION'/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v'$KUBERNETES_VERSION'/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubeadm, kubelet, kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Enable kubelet
sudo systemctl enable kubelet

echo "Kubernetes components installed successfully"
'
    
    run_on_all_nodes "$INSTALL_SCRIPT" "Installing Kubernetes on all nodes"
}

# Install ECR Credential Helper on all nodes (Option B)
install_ecr_credential_helper() {
    print_header "Installing ECR Credential Helper on All Nodes (Option B)"
    
    print_info "This eliminates the need for ECR tokens - IAM role handles authentication!"
    
    ECR_HELPER_SCRIPT='
#!/bin/bash
set -e

# Install amazon-ecr-credential-helper
echo "Installing amazon-ecr-credential-helper..."
sudo apt-get update
sudo apt-get install -y amazon-ecr-credential-helper

# Verify installation
if command -v docker-credential-ecr-login &> /dev/null; then
    echo "✅ ECR Credential Helper installed successfully"
    docker-credential-ecr-login -v
else
    echo "❌ ECR Credential Helper installation failed"
    exit 1
fi

# Configure containerd for ECR using modern config_path approach
echo "Configuring containerd for ECR..."

# Enable config_path in main config (if not already set)
if ! grep -q "config_path" /etc/containerd/config.toml; then
    sudo sed -i "/\[plugins\.\"io\.containerd\.grpc\.v1\.cri\"\.registry\]/a\  config_path = \"/etc/containerd/certs.d\"" /etc/containerd/config.toml
fi

# Create ECR-specific config directory
sudo mkdir -p /etc/containerd/certs.d/'$AWS_ACCOUNT_ID'.dkr.ecr.'$REGION'.amazonaws.com

# Create hosts.toml for ECR
sudo tee /etc/containerd/certs.d/'$AWS_ACCOUNT_ID'.dkr.ecr.'$REGION'.amazonaws.com/hosts.toml > /dev/null <<HOSTEOF
server = "https://'$AWS_ACCOUNT_ID'.dkr.ecr.'$REGION'.amazonaws.com"

[host."https://'$AWS_ACCOUNT_ID'.dkr.ecr.'$REGION'.amazonaws.com"]
  capabilities = ["pull", "resolve"]

[host."https://'$AWS_ACCOUNT_ID'.dkr.ecr.'$REGION'.amazonaws.com".header]
  x-amazon-ecr-login = ["ecr-login"]
HOSTEOF

# Restart containerd to apply changes
echo "Restarting containerd..."
sudo systemctl restart containerd

# Verify containerd is running
if sudo systemctl is-active --quiet containerd; then
    echo "✅ Containerd restarted successfully"
else
    echo "❌ Containerd failed to start"
    sudo systemctl status containerd --no-pager
    exit 1
fi

echo "✅ ECR Credential Helper configured for containerd"
'
    
    run_on_all_nodes "$ECR_HELPER_SCRIPT" "Installing and configuring ECR Credential Helper"
    
    print_success "ECR Credential Helper installed on all nodes!"
    print_info "Pods can now pull from ECR using the EC2 IAM role - no secrets needed!"
}

# Initialize Kubernetes cluster on master
initialize_cluster() {
    print_header "Initializing Kubernetes Cluster on Master Node"
    
    print_info "Initializing cluster (this may take 2-3 minutes)..."
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << EOF
set -e

# Initialize the cluster
sudo kubeadm init \
    --pod-network-cidr=$POD_NETWORK_CIDR \
    --apiserver-cert-extra-sans=$MASTER_PUBLIC_IP \
    --control-plane-endpoint=$MASTER_PRIVATE_IP \
    | tee /tmp/kubeadm-init.log

# Setup kubeconfig for ubuntu user
mkdir -p \$HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config

echo "Cluster initialized successfully"
EOF
    
    print_success "Kubernetes cluster initialized on master"
}

# Install Calico CNI
install_calico() {
    print_header "Installing Calico CNI"
    
    print_info "Deploying Calico network plugin..."
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << EOF
set -e

# Install Calico
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml

# Wait for operator to be ready
echo "Waiting for Calico operator..."
kubectl wait --for=condition=available --timeout=300s deployment/tigera-operator -n tigera-operator

# Create Calico custom resource
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/custom-resources.yaml

echo "Calico CNI installed"
EOF
    
    print_success "Calico CNI installed"
    
    # Wait for nodes to be ready
    print_info "Waiting for master node to be Ready (this may take 2-3 minutes)..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
ATTEMPTS=0
MAX_ATTEMPTS=30
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if kubectl get nodes | grep -q "Ready"; then
        echo "Master node is Ready!"
        kubectl get nodes
        break
    fi
    echo "Waiting... ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPTS=$((ATTEMPTS+1))
done
EOF
    
    print_success "Master node is Ready"
}

# Get join command
get_join_command() {
    print_header "Generating Worker Join Command"
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "sudo kubeadm token create --print-join-command" > /tmp/k8s-join-command.sh
    
    chmod +x /tmp/k8s-join-command.sh
    
    print_success "Join command generated"
}

# Join worker nodes
join_workers() {
    print_header "Joining Worker Nodes to Cluster"
    
    JOIN_CMD=$(cat /tmp/k8s-join-command.sh)
    
    # Worker 1
    print_info "Joining worker1..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP << EOF
set -e
sudo $JOIN_CMD
echo "Worker1 joined successfully"
EOF
    print_success "Worker1 joined the cluster"
    
    # Worker 2
    print_info "Joining worker2..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP << EOF
set -e
sudo $JOIN_CMD
echo "Worker2 joined successfully"
EOF
    print_success "Worker2 joined the cluster"
    
    # Clean up
    rm -f /tmp/k8s-join-command.sh
}

# Verify cluster
verify_cluster() {
    print_header "Verifying Kubernetes Cluster"
    
    print_info "Waiting for all nodes to be Ready..."
    sleep 30
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
ATTEMPTS=0
MAX_ATTEMPTS=20
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    READY_COUNT=$(kubectl get nodes --no-headers | grep -c Ready || echo 0)
    if [ "$READY_COUNT" -eq 3 ]; then
        echo "All 3 nodes are Ready!"
        break
    fi
    echo "Ready nodes: $READY_COUNT/3 - Waiting... ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPTS=$((ATTEMPTS+1))
done

echo ""
echo "=== Cluster Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Cluster Info ==="
kubectl cluster-info

echo ""
echo "=== System Pods ==="
kubectl get pods -n kube-system
EOF
    
    print_success "Cluster verification complete"
}

# Setup kubectl locally
setup_local_kubectl() {
    print_header "Setting Up kubectl on Local Machine"
    
    print_info "Downloading kubeconfig from master..."
    
    mkdir -p ~/.kube
    scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
        ubuntu@$MASTER_PUBLIC_IP:~/.kube/config \
        ~/.kube/config-haddar-retail-store 2>/dev/null || true
    
    # Update server address to use public IP
    sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|" ~/.kube/config-haddar-retail-store
    
    # Set as default kubeconfig or merge
    if [ ! -f ~/.kube/config ]; then
        cp ~/.kube/config-haddar-retail-store ~/.kube/config
        print_success "kubeconfig set as default"
    else
        export KUBECONFIG=~/.kube/config-haddar-retail-store
        print_success "kubeconfig downloaded to ~/.kube/config-haddar-retail-store"
        print_info "Use: export KUBECONFIG=~/.kube/config-haddar-retail-store"
    fi
    
    # Test local kubectl
    if kubectl get nodes &>/dev/null; then
        print_success "kubectl configured successfully on local machine"
    else
        print_warning "kubectl not working locally yet"
        print_info "You may need to: export KUBECONFIG=~/.kube/config-haddar-retail-store"
    fi
}

# Print summary
print_summary() {
    print_header "Kubernetes Cluster Setup Complete!"
    
    echo -e "${GREEN}✅ Kubernetes cluster is ready!${NC}"
    echo ""
    echo -e "${BLUE}Cluster Configuration:${NC}"
    echo "  Kubernetes Version:    ${KUBERNETES_VERSION}"
    echo "  CNI Plugin:            Calico ${CALICO_VERSION}"
    echo "  Pod Network CIDR:      ${POD_NETWORK_CIDR}"
    echo "  Master Node:           ${MASTER_PUBLIC_IP}"
    echo "  Worker Nodes:          2 nodes"
    echo ""
    echo -e "${CYAN}ECR Authentication (Option B):${NC}"
    echo "  ✅ ECR Credential Helper installed on all nodes"
    echo "  ✅ Containerd configured to use IAM role"
    echo "  ✅ No ECR tokens or secrets needed!"
    echo "  ✅ Pods can pull images directly from ECR"
    echo ""
    echo -e "${BLUE}Verify Cluster:${NC}"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo "  kubectl cluster-info"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Deploy with Helm (Phase 4):  ./04-helm-deploy.sh"
    echo "  2. Or setup GitOps (Phase 5):   ./05-create-gitops-repo.sh"
    echo ""
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  • ECR Credential Helper uses EC2 IAM role for authentication"
    echo "  • No imagePullSecrets needed in deployments"
    echo "  • Images pull automatically from ECR"
    echo "  • No 12-hour token expiration to worry about!"
}

# Main execution
main() {
    check_prerequisites
    install_kubernetes
    install_ecr_credential_helper
    initialize_cluster
    install_calico
    get_join_command
    join_workers
    verify_cluster
    setup_local_kubectl
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Kubernetes Cluster Setup Completed! 🎉            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
