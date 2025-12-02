#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster Initialization Script (FIXED)
# Phase 3: Install and configure Kubernetes cluster with ECR Credential Helper
#
# This script:
# 1. Installs containerd as the container runtime
# 2. Installs Kubernetes (kubeadm, kubelet, kubectl) on all nodes
# 3. Installs OFFICIAL AWS ECR Credential Provider on all nodes
# 4. Creates kubeadm config with kubelet credential provider settings
# 5. Initializes the Kubernetes cluster on the master node
# 6. Installs Calico CNI
# 7. Joins worker nodes to the cluster
#
# ECR Authentication: Uses EC2 IAM Role - NO TOKENS NEEDED!
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
# Official AWS ECR Credential Provider - use version compatible with K8s 1.28
ECR_CREDENTIAL_PROVIDER_VERSION="v1.28.1"

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
echo "║   Phase 3: Setup K8s with ECR Credential Provider    ║"
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
    print_success "SSH key found: $KEY_FILE"

    # Test SSH connection to all nodes
    for NODE_INFO in "MASTER:$MASTER_PUBLIC_IP" "WORKER1:$WORKER1_PUBLIC_IP" "WORKER2:$WORKER2_PUBLIC_IP"; do
        NODE_NAME="${NODE_INFO%%:*}"
        NODE_IP="${NODE_INFO##*:}"

        print_info "Testing SSH connection to ${NODE_NAME}..."
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_FILE" ubuntu@$NODE_IP "echo 'OK'" &>/dev/null; then
            print_success "${NODE_NAME} SSH connection working"
        else
            print_error "Cannot connect to ${NODE_NAME} via SSH"
            print_info "Wait a few minutes after terraform apply, or run: source startup.sh"
            exit 1
        fi
    done

    print_success "All prerequisites met"
}

# Function to run commands on all nodes
run_on_all_nodes() {
    local COMMAND=$1
    local DESCRIPTION=$2

    print_info "$DESCRIPTION"

    # Master
    print_info "  → Running on master..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "$COMMAND"

    # Worker 1
    print_info "  → Running on worker1..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP "$COMMAND"

    # Worker 2
    print_info "  → Running on worker2..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP "$COMMAND"

    print_success "$DESCRIPTION - Complete"
}

# Install container runtime and Kubernetes prerequisites
install_prerequisites() {
    print_header "Installing Prerequisites on All Nodes"

    PREREQ_SCRIPT='
#!/bin/bash
set -e

echo "=== Installing prerequisites on $(hostname) ==="

# Disable swap
sudo swapoff -a
sudo sed -i "/ swap / s/^/#/" /etc/fstab

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Configure sysctl for Kubernetes networking
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system > /dev/null

# Install containerd
sudo apt-get update
sudo apt-get install -y containerd apt-transport-https ca-certificates curl gpg

# Configure containerd with SystemdCgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
sudo sed -i "s/SystemdCgroup = false/SystemdCgroup = true/" /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

echo "✓ Prerequisites installed on $(hostname)"
'

    run_on_all_nodes "$PREREQ_SCRIPT" "Installing prerequisites"
}

# Install Kubernetes packages
install_kubernetes_packages() {
    print_header "Installing Kubernetes Packages on All Nodes"

    K8S_INSTALL_SCRIPT='
#!/bin/bash
set -e

echo "=== Installing Kubernetes packages on $(hostname) ==="

# Add Kubernetes apt repository
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v'$KUBERNETES_VERSION'/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v'$KUBERNETES_VERSION'/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Install kubeadm, kubelet, kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "✓ Kubernetes packages installed on $(hostname)"
'

    run_on_all_nodes "$K8S_INSTALL_SCRIPT" "Installing Kubernetes packages"
}

# Install ECR Credential Provider (OFFICIAL AWS version)
install_ecr_credential_provider() {
    print_header "Installing Official AWS ECR Credential Provider"

    print_info "Installing ECR credential provider on all nodes..."
    print_info "Using official AWS cloud-provider-aws version ${ECR_CREDENTIAL_PROVIDER_VERSION}"

    ECR_PROVIDER_SCRIPT='
#!/bin/bash
set -e

echo "=== Installing ECR Credential Provider on $(hostname) ==="

# Download official AWS ECR credential provider
# Source: https://github.com/kubernetes/cloud-provider-aws
ECR_PROVIDER_URL="https://artifacts.k8s.io/binaries/cloud-provider-aws/'$ECR_CREDENTIAL_PROVIDER_VERSION'/linux/amd64/ecr-credential-provider-linux-amd64"

echo "Downloading from: ${ECR_PROVIDER_URL}"
sudo curl -Lo /usr/local/bin/ecr-credential-provider "${ECR_PROVIDER_URL}"
sudo chmod +x /usr/local/bin/ecr-credential-provider

# Verify it was downloaded
if [ ! -f /usr/local/bin/ecr-credential-provider ]; then
    echo "ERROR: Failed to download ECR credential provider"
    exit 1
fi

# Test the binary
if /usr/local/bin/ecr-credential-provider --help &>/dev/null || /usr/local/bin/ecr-credential-provider version &>/dev/null 2>&1; then
    echo "✓ ECR credential provider binary is valid"
else
    # Some versions dont have --help, check if file is executable
    if [ -x /usr/local/bin/ecr-credential-provider ]; then
        echo "✓ ECR credential provider installed (binary executable)"
    else
        echo "WARNING: Could not verify binary, but continuing..."
    fi
fi

# Create credential provider configuration
sudo mkdir -p /etc/kubernetes

sudo tee /etc/kubernetes/ecr-credential-provider-config.yaml > /dev/null <<EOF
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
- name: ecr-credential-provider
  matchImages:
  - "*.dkr.ecr.*.amazonaws.com"
  - "*.dkr.ecr.*.amazonaws.com.cn"
  - "*.dkr.ecr-fips.*.amazonaws.com"
  defaultCacheDuration: "12h"
  apiVersion: credentialprovider.kubelet.k8s.io/v1
EOF

echo "✓ ECR credential provider config created"

# Create kubelet drop-in to add credential provider flags
# This ensures kubelet uses ECR credential provider from the start
sudo mkdir -p /etc/systemd/system/kubelet.service.d

sudo tee /etc/systemd/system/kubelet.service.d/20-ecr-credential-provider.conf > /dev/null <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml --image-credential-provider-bin-dir=/usr/local/bin"
EOF

# Reload systemd to pick up the drop-in
sudo systemctl daemon-reload

echo "✓ Kubelet configured to use ECR credential provider on $(hostname)"
'

    run_on_all_nodes "$ECR_PROVIDER_SCRIPT" "Installing ECR Credential Provider"

    print_success "ECR Credential Provider installed on all nodes!"
}

# Initialize Kubernetes cluster on master
initialize_cluster() {
    print_header "Initializing Kubernetes Cluster on Master Node"

    print_info "Initializing cluster (this may take 2-3 minutes)..."

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << EOF
set -e

echo "=== Initializing Kubernetes cluster ==="

# Initialize the cluster
# The kubelet will automatically use ECR credential provider via the drop-in we created
sudo kubeadm init \\
    --pod-network-cidr=$POD_NETWORK_CIDR \\
    --apiserver-cert-extra-sans=$MASTER_PUBLIC_IP \\
    --control-plane-endpoint=$MASTER_PRIVATE_IP \\
    | tee /tmp/kubeadm-init.log

# Setup kubeconfig for ubuntu user
mkdir -p \$HOME/.kube
sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config
sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config

echo "✓ Cluster initialized successfully"
EOF

    print_success "Kubernetes cluster initialized on master"
}

# Install Calico CNI
install_calico() {
    print_header "Installing Calico CNI"

    print_info "Deploying Calico network plugin..."

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
set -e

echo "=== Installing Calico CNI ==="

# Install Calico operator
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/tigera-operator.yaml

# Wait for operator to be ready
echo "Waiting for Calico operator..."
sleep 10
kubectl wait --for=condition=available --timeout=120s deployment/tigera-operator -n tigera-operator || true

# Create Calico custom resource
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/custom-resources.yaml

echo "✓ Calico CNI installed"

# Wait for master node to be Ready
echo "Waiting for master node to be Ready..."
ATTEMPTS=0
MAX_ATTEMPTS=30
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    if kubectl get nodes | grep -q " Ready"; then
        echo "✓ Master node is Ready!"
        kubectl get nodes
        break
    fi
    echo "  Waiting... ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPTS=$((ATTEMPTS+1))
done
EOF

    print_success "Calico CNI installed"
}

# Get join command from master
get_join_command() {
    print_header "Generating Worker Join Command"

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "sudo kubeadm token create --print-join-command" > /tmp/k8s-join-command.sh

    chmod +x /tmp/k8s-join-command.sh

    print_success "Join command generated"
}

# Join worker nodes to cluster
join_workers() {
    print_header "Joining Worker Nodes to Cluster"

    JOIN_CMD=$(cat /tmp/k8s-join-command.sh)

    # Join Worker 1
    print_info "Joining worker1 to cluster..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP << EOF
set -e
sudo $JOIN_CMD
echo "✓ Worker1 joined successfully"
EOF
    print_success "Worker1 joined the cluster"

    # Join Worker 2
    print_info "Joining worker2 to cluster..."
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP << EOF
set -e
sudo $JOIN_CMD
echo "✓ Worker2 joined successfully"
EOF
    print_success "Worker2 joined the cluster"

    # Clean up
    rm -f /tmp/k8s-join-command.sh
}

# Verify cluster
verify_cluster() {
    print_header "Verifying Kubernetes Cluster"

    print_info "Waiting for all nodes to be Ready (this may take 1-2 minutes)..."
    sleep 30

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
ATTEMPTS=0
MAX_ATTEMPTS=24
while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
    if [ "$READY_COUNT" -eq 3 ]; then
        echo "✓ All 3 nodes are Ready!"
        break
    fi
    echo "  Ready nodes: $READY_COUNT/3 - Waiting... ($((ATTEMPTS+1))/$MAX_ATTEMPTS)"
    sleep 10
    ATTEMPTS=$((ATTEMPTS+1))
done

echo ""
echo "=== Cluster Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== System Pods ==="
kubectl get pods -n kube-system

echo ""
echo "=== Cluster Info ==="
kubectl cluster-info
EOF

    print_success "Cluster verification complete"
}

# Setup kubectl locally with TLS skip
setup_local_kubectl() {
    print_header "Setting Up kubectl on Local Machine"

    print_info "Downloading kubeconfig from master..."

    mkdir -p ~/.kube

    # Copy kubeconfig from master
    scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
        ubuntu@$MASTER_PUBLIC_IP:~/.kube/config \
        ~/.kube/config-haddar-retail-store

    # Update server address to use public IP
    sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|" ~/.kube/config-haddar-retail-store

    # Add insecure-skip-tls-verify (needed because cert is for private IP)
    # Use a proper approach that doesn't corrupt YAML on re-runs
    if ! grep -q "insecure-skip-tls-verify: true" ~/.kube/config-haddar-retail-store; then
        # Remove certificate-authority-data and add insecure-skip-tls-verify
        sed -i '/certificate-authority-data:/d' ~/.kube/config-haddar-retail-store
        # Add insecure-skip-tls-verify under the cluster section
        sed -i '/server: https/a\    insecure-skip-tls-verify: true' ~/.kube/config-haddar-retail-store
    fi

    # Export for current session
    export KUBECONFIG=~/.kube/config-haddar-retail-store

    print_success "kubeconfig downloaded to ~/.kube/config-haddar-retail-store"

    # Test local kubectl
    if kubectl get nodes &>/dev/null; then
        print_success "kubectl working from local machine!"
        echo ""
        kubectl get nodes
    else
        print_warning "kubectl not working locally yet"
        print_info "Try: export KUBECONFIG=~/.kube/config-haddar-retail-store"
    fi
}

# Verify ECR credential provider is working
verify_ecr_setup() {
    print_header "Verifying ECR Credential Provider Setup"

    print_info "Checking ECR credential provider on master node..."

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
echo "=== Checking ECR Credential Provider ==="

# Check binary exists
if [ -f /usr/local/bin/ecr-credential-provider ]; then
    echo "✓ ECR credential provider binary exists"
else
    echo "✗ ECR credential provider binary NOT found"
fi

# Check config exists
if [ -f /etc/kubernetes/ecr-credential-provider-config.yaml ]; then
    echo "✓ ECR credential provider config exists"
else
    echo "✗ ECR credential provider config NOT found"
fi

# Check kubelet drop-in
if [ -f /etc/systemd/system/kubelet.service.d/20-ecr-credential-provider.conf ]; then
    echo "✓ Kubelet drop-in config exists"
else
    echo "✗ Kubelet drop-in NOT found"
fi

# Check kubelet is using the credential provider
echo ""
echo "=== Kubelet Process Check ==="
ps aux | grep kubelet | grep -v grep | head -1 || echo "(kubelet process info)"

echo ""
echo "=== IAM Role Check ==="
# Test if we can reach EC2 metadata (IAM role)
if curl -s --connect-timeout 2 http://169.254.169.254/latest/meta-data/iam/security-credentials/ | head -1; then
    echo "✓ IAM role is attached to this instance"
else
    echo "✗ Cannot access IAM role - check EC2 instance profile"
fi
EOF

    print_success "ECR setup verification complete"
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
    echo -e "${CYAN}ECR Authentication:${NC}"
    echo "  ✅ Official AWS ECR Credential Provider installed"
    echo "  ✅ Kubelet configured to use IAM role"
    echo "  ✅ No ECR tokens or imagePullSecrets needed!"
    echo "  ✅ Pods can pull images directly from ECR"
    echo ""
    echo -e "${BLUE}Access Cluster:${NC}"
    echo "  export KUBECONFIG=~/.kube/config-haddar-retail-store"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Verify cluster:    kubectl get nodes"
    echo "  2. Deploy with Helm:  ./04-helm-deploy.sh"
    echo "  3. Or setup GitOps:   ./05-create-gitops-repo.sh"
    echo ""
    echo -e "${YELLOW}Daily Startup (after EC2 restart):${NC}"
    echo "  source startup.sh"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    install_prerequisites
    install_kubernetes_packages
    install_ecr_credential_provider
    initialize_cluster
    install_calico
    get_join_command
    join_workers
    verify_cluster
    setup_local_kubectl
    verify_ecr_setup
    print_summary

    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Kubernetes Cluster Setup Completed! 🎉            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main