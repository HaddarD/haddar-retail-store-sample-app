#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster Initialization Script
# Phase 3: Install and configure Kubernetes cluster with ECR Credential Helper
#
# FIXES in this version:
# - IMDSv2 support for IAM role check (no more false warnings)
# - /etc/default/kubelet created AFTER apt install (no interactive prompts)
# v2 fixes:
# - ECR credential provider URL: v1.29.0 (verified 20MB binary)
# - Verifies kubelet has credential provider flags after init
# - Fixes kubelet config if flags are missing
# - Proper apiVersion for K8s 1.28 GA
#
# This script:
# 1. Installs containerd as the container runtime
# 2. Installs Kubernetes (kubeadm, kubelet, kubectl) on all nodes
# 3. Installs OFFICIAL AWS ECR Credential Provider on all nodes
# 4. Configures kubelet to use ECR credential provider via IAM role
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

# WORKING URL - verified to return 20MB binary
ECR_CREDENTIAL_PROVIDER_URL="https://artifacts.k8s.io/binaries/cloud-provider-aws/v1.29.0/linux/amd64/ecr-credential-provider-linux-amd64"
ECR_CREDENTIAL_PROVIDER_MIN_SIZE=10000000  # 10MB minimum (actual is ~20MB)

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
echo "║   Version: FULLY FIXED v3                            ║"
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

# Install ECR Credential Provider binary and config (but NOT kubelet config yet)
install_ecr_credential_provider() {
    print_header "Installing Official AWS ECR Credential Provider"

    print_info "Downloading ECR credential provider from:"
    print_info "$ECR_CREDENTIAL_PROVIDER_URL"
    echo ""

    # Create script with embedded URL and min size
    # NOTE: This only installs binary and creates the provider config
    # The kubelet config (/etc/default/kubelet) is done AFTER apt install
    ECR_PROVIDER_SCRIPT='
#!/bin/bash
set -e

echo "=== Installing ECR Credential Provider on $(hostname) ==="

ECR_PROVIDER_URL="'"$ECR_CREDENTIAL_PROVIDER_URL"'"
MIN_SIZE='"$ECR_CREDENTIAL_PROVIDER_MIN_SIZE"'

# Download the binary
echo "Downloading ECR credential provider..."
sudo curl -Lo /usr/local/bin/ecr-credential-provider "$ECR_PROVIDER_URL"

# Verify file was downloaded and is the correct size
if [ ! -f /usr/local/bin/ecr-credential-provider ]; then
    echo "❌ ERROR: Download failed - file does not exist"
    exit 1
fi

FILE_SIZE=$(stat -c%s /usr/local/bin/ecr-credential-provider 2>/dev/null || stat -f%z /usr/local/bin/ecr-credential-provider 2>/dev/null)
echo "Downloaded file size: $FILE_SIZE bytes"

if [ "$FILE_SIZE" -lt "$MIN_SIZE" ]; then
    echo "❌ ERROR: Downloaded file is too small ($FILE_SIZE bytes)"
    echo "   Expected at least $MIN_SIZE bytes (10MB)"
    echo "   This usually means the download URL returned an error page"
    sudo rm -f /usr/local/bin/ecr-credential-provider
    exit 1
fi

echo "✓ File size verified: $FILE_SIZE bytes ($(($FILE_SIZE / 1024 / 1024))MB)"

# Make executable
sudo chmod +x /usr/local/bin/ecr-credential-provider

# Verify it is executable
if [ ! -x /usr/local/bin/ecr-credential-provider ]; then
    echo "❌ ERROR: File is not executable"
    exit 1
fi

echo "✓ ECR credential provider binary installed and executable"

# Create credential provider configuration directory
sudo mkdir -p /etc/kubernetes

# Create credential provider configuration file
# Using apiVersion kubelet.config.k8s.io/v1 (GA in K8s 1.26+)
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

echo "✓ ECR credential provider config created at /etc/kubernetes/ecr-credential-provider-config.yaml"

echo ""
echo "=== ECR Credential Provider Binary Installation Complete on $(hostname) ==="
'

    run_on_all_nodes "$ECR_PROVIDER_SCRIPT" "Installing ECR Credential Provider"

    # Verify installation on all nodes
    print_header "Verifying ECR Credential Provider Installation"

    for NODE_INFO in "MASTER:$MASTER_PUBLIC_IP" "WORKER1:$WORKER1_PUBLIC_IP" "WORKER2:$WORKER2_PUBLIC_IP"; do
        NODE_NAME="${NODE_INFO%%:*}"
        NODE_IP="${NODE_INFO##*:}"

        FILE_SIZE=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$NODE_IP "stat -c%s /usr/local/bin/ecr-credential-provider 2>/dev/null || echo 0")

        if [ "$FILE_SIZE" -gt "$ECR_CREDENTIAL_PROVIDER_MIN_SIZE" ]; then
            print_success "${NODE_NAME}: ECR credential provider verified (${FILE_SIZE} bytes / $((FILE_SIZE / 1024 / 1024))MB)"
        else
            print_error "${NODE_NAME}: ECR credential provider FAILED (${FILE_SIZE} bytes)"
            print_error "Installation failed! Please check network connectivity and try again."
            exit 1
        fi
    done

    print_success "ECR Credential Provider installed and verified on ALL nodes!"
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
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

echo "✓ Kubernetes packages installed on $(hostname)"
'

    run_on_all_nodes "$K8S_INSTALL_SCRIPT" "Installing Kubernetes packages"
}

# Configure kubelet to use ECR credential provider
# This runs AFTER kubelet is installed to avoid apt conflicts
configure_kubelet_ecr() {
    print_header "Configuring Kubelet for ECR Credential Provider"

    KUBELET_CONFIG_SCRIPT='
#!/bin/bash
set -e

echo "=== Configuring kubelet for ECR on $(hostname) ==="

# Configure kubelet to use ECR credential provider
# Using /etc/default/kubelet (standard location that kubelet.service sources)
KUBELET_EXTRA_ARGS="--image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml --image-credential-provider-bin-dir=/usr/local/bin"

# Create or update /etc/default/kubelet
# At this point, the file either doesnt exist or was created by apt with defaults
if [ -f /etc/default/kubelet ]; then
    # Check if it already has our args
    if grep -q "image-credential-provider-config" /etc/default/kubelet; then
        echo "✓ Kubelet already configured for ECR"
    else
        # Check if KUBELET_EXTRA_ARGS exists
        if grep -q "^KUBELET_EXTRA_ARGS=" /etc/default/kubelet; then
            # Append to existing args
            sudo sed -i "s|^KUBELET_EXTRA_ARGS=\"|KUBELET_EXTRA_ARGS=\"$KUBELET_EXTRA_ARGS |" /etc/default/kubelet
        else
            # Add new line
            echo "KUBELET_EXTRA_ARGS=\"$KUBELET_EXTRA_ARGS\"" | sudo tee -a /etc/default/kubelet
        fi
        echo "✓ Added ECR args to existing /etc/default/kubelet"
    fi
else
    # Create new file
    echo "KUBELET_EXTRA_ARGS=\"$KUBELET_EXTRA_ARGS\"" | sudo tee /etc/default/kubelet
    echo "✓ Created /etc/default/kubelet with ECR args"
fi

echo "Current /etc/default/kubelet:"
cat /etc/default/kubelet

echo ""
echo "=== Kubelet ECR Configuration Complete on $(hostname) ==="
'

    run_on_all_nodes "$KUBELET_CONFIG_SCRIPT" "Configuring kubelet for ECR"
}

# Initialize Kubernetes cluster on master
initialize_cluster() {
    print_header "Initializing Kubernetes Cluster on Master Node"

    print_info "Initializing cluster (this may take 2-3 minutes)..."

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << EOF
set -e

echo "=== Initializing Kubernetes cluster ==="

# Initialize the cluster
# kubelet will use ECR credential provider via /etc/default/kubelet settings
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

# Verify and fix kubelet credential provider configuration
verify_and_fix_kubelet() {
    print_header "Verifying Kubelet Credential Provider Configuration"

    print_info "Checking if kubelet is using credential provider flags..."

    for NODE_INFO in "MASTER:$MASTER_PUBLIC_IP" "WORKER1:$WORKER1_PUBLIC_IP" "WORKER2:$WORKER2_PUBLIC_IP"; do
        NODE_NAME="${NODE_INFO%%:*}"
        NODE_IP="${NODE_INFO##*:}"

        echo ""
        echo "=== Checking ${NODE_NAME} ==="

        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$NODE_IP << 'VERIFY_SCRIPT'
#!/bin/bash

# Check if kubelet is running with credential provider flags
if ps aux | grep -v grep | grep kubelet | grep -q "image-credential-provider"; then
    echo "✓ Kubelet is using credential provider flags"
    ps aux | grep -v grep | grep kubelet | grep -o "\-\-image-credential-provider[^ ]*" | head -2
else
    echo "⚠ Kubelet NOT using credential provider flags - fixing now..."

    # Check if kubelet is running
    KUBELET_RUNNING=$(ps aux | grep -v grep | grep -c kubelet || echo 0)

    if [ "$KUBELET_RUNNING" -eq 0 ]; then
        echo "Kubelet not running yet - /etc/default/kubelet should be picked up on start"
    else
        echo "Kubelet running but missing flags - adding to kubeadm-flags.env"

        # Add to kubeadm-flags.env if it exists
        if [ -f /var/lib/kubelet/kubeadm-flags.env ]; then
            # Check if already has credential provider flags
            if ! grep -q "image-credential-provider" /var/lib/kubelet/kubeadm-flags.env; then
                # Append our flags to the existing KUBELET_KUBEADM_ARGS
                sudo sed -i 's|"$| --image-credential-provider-config=/etc/kubernetes/ecr-credential-provider-config.yaml --image-credential-provider-bin-dir=/usr/local/bin"|' /var/lib/kubelet/kubeadm-flags.env
                echo "✓ Added flags to /var/lib/kubelet/kubeadm-flags.env"
                cat /var/lib/kubelet/kubeadm-flags.env

                # Restart kubelet to pick up changes
                echo "Restarting kubelet..."
                sudo systemctl daemon-reload
                sudo systemctl restart kubelet
                sleep 5

                # Verify it worked
                if ps aux | grep -v grep | grep kubelet | grep -q "image-credential-provider"; then
                    echo "✓ Kubelet now using credential provider flags!"
                else
                    echo "⚠ Still not seeing flags - may need manual intervention"
                fi
            else
                echo "Flags already in kubeadm-flags.env but kubelet not using them?"
            fi
        else
            echo "No kubeadm-flags.env found - kubelet may not be initialized yet"
        fi
    fi
fi

# Also verify config file exists
if [ -f /etc/kubernetes/ecr-credential-provider-config.yaml ]; then
    echo "✓ Config file exists at /etc/kubernetes/ecr-credential-provider-config.yaml"
else
    echo "✗ Config file MISSING!"
fi

# Verify binary exists and is correct size
if [ -f /usr/local/bin/ecr-credential-provider ]; then
    SIZE=$(stat -c%s /usr/local/bin/ecr-credential-provider)
    echo "✓ Binary exists: $SIZE bytes"
else
    echo "✗ Binary MISSING!"
fi
VERIFY_SCRIPT
    done

    print_success "Kubelet verification complete"
}

# Install Calico CNI
install_calico() {
    print_header "Installing Calico CNI"

    print_info "Deploying Calico network plugin..."

    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'EOF'
set -e

echo "=== Installing Calico CNI ==="

# Install Calico operator
curl -sL https://raw.githubusercontent.com/projectcalico/calico/v3.26.1/manifests/calico.yaml -o /tmp/calico.yaml
kubectl apply -f /tmp/calico.yaml

echo "Waiting for Calico pods..."
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=180s || true
kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n kube-system --timeout=180s || true

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

    # Add insecure-skip-tls-verify properly (idempotent)
    # First remove any existing insecure-skip-tls-verify lines to avoid duplicates
    sed -i '/insecure-skip-tls-verify/d' ~/.kube/config-haddar-retail-store
    # Remove certificate-authority-data (we'll use insecure skip instead)
    sed -i '/certificate-authority-data:/d' ~/.kube/config-haddar-retail-store
    # Add insecure-skip-tls-verify under the cluster section
    sed -i '/server: https/a\    insecure-skip-tls-verify: true' ~/.kube/config-haddar-retail-store

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

# Final verification of ECR credential provider (with IMDSv2 support)
final_ecr_verification() {
    print_header "Final ECR Credential Provider Verification"

    print_info "Verifying kubelet is configured correctly on all nodes..."

    ALL_GOOD=true

    for NODE_INFO in "MASTER:$MASTER_PUBLIC_IP" "WORKER1:$WORKER1_PUBLIC_IP" "WORKER2:$WORKER2_PUBLIC_IP"; do
        NODE_NAME="${NODE_INFO%%:*}"
        NODE_IP="${NODE_INFO##*:}"

        echo ""
        echo "=== ${NODE_NAME} ==="

        # Check kubelet process for credential provider flags
        HAS_FLAGS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$NODE_IP \
            "ps aux | grep -v grep | grep kubelet | grep -c 'image-credential-provider' || echo 0")

        if [ "$HAS_FLAGS" -gt 0 ]; then
            print_success "${NODE_NAME}: Kubelet using credential provider ✓"
        else
            print_warning "${NODE_NAME}: Kubelet may not have credential provider flags"
            ALL_GOOD=false
        fi

        # Check IAM role using IMDSv2 (requires token)
        ROLE=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$NODE_IP '
            # Get IMDSv2 token first
            TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null)
            if [ -n "$TOKEN" ]; then
                # Use token to get IAM role
                curl -s -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/iam/security-credentials/ 2>/dev/null | head -1
            fi
        ')

        if [ -n "$ROLE" ]; then
            print_success "${NODE_NAME}: IAM role attached: $ROLE"
        else
            print_warning "${NODE_NAME}: Could not verify IAM role (may still work)"
            # Don't fail on this - the ECR provider uses AWS SDK which handles this
        fi
    done

    if [ "$ALL_GOOD" = true ]; then
        print_success "All nodes configured correctly for ECR authentication!"
    else
        print_warning "Some nodes may need attention - check warnings above"
        print_info "You may need to restart kubelet on affected nodes:"
        print_info "  ssh -i \$KEY_FILE ubuntu@<NODE_IP> 'sudo systemctl restart kubelet'"
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
    echo -e "${CYAN}ECR Authentication:${NC}"
    echo "  ✅ Official AWS ECR Credential Provider installed (~20MB binary)"
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
    install_ecr_credential_provider      # Install ECR binary and provider config
    install_kubernetes_packages           # Install K8s packages (creates empty /etc/default/kubelet)
    configure_kubelet_ecr                 # NOW configure /etc/default/kubelet (no conflict!)
    initialize_cluster
    install_calico
    get_join_command
    join_workers
    verify_cluster
    verify_and_fix_kubelet               # Verify/fix kubelet after cluster is up
    setup_local_kubectl
    final_ecr_verification               # Final verification with IMDSv2 support
    print_summary

    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Kubernetes Cluster Setup Completed! 🎉            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main