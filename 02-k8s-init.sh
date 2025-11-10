#!/bin/bash

################################################################################
# Retail Store K8s Project - Kubernetes Cluster Initialization Script
# Chat 2: Install containerd, kubeadm, kubelet, kubectl and initialize cluster
################################################################################

set -e  # Exit on any error

# Load environment variables
if [ ! -f deployment-info.txt ]; then
    echo "❌ ERROR: deployment-info.txt not found!"
    echo "Please run 01-infrastructure.sh first"
    exit 1
fi

source deployment-info.txt

# Configuration
K8S_VERSION="1.28"
POD_CIDR="10.244.0.0/16"
CALICO_VERSION="v3.26.1"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    echo -e "${BLUE}ℹ️  $1${NC}"
}

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    if [ -z "$MASTER_PUBLIC_IP" ] || [ -z "$WORKER1_PUBLIC_IP" ] || [ -z "$WORKER2_PUBLIC_IP" ]; then
        print_error "Instance IPs not found in deployment-info.txt"
        exit 1
    fi
    print_success "Instance IPs loaded"
    
    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key not found: $KEY_FILE"
        exit 1
    fi
    print_success "SSH key found"
    
    # Test SSH connectivity
    print_info "Testing SSH connectivity to master..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "echo 'SSH OK'" &> /dev/null; then
        print_success "Master node reachable"
    else
        print_error "Cannot connect to master node"
        exit 1
    fi
    
    print_info "Testing SSH connectivity to worker1..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP "echo 'SSH OK'" &> /dev/null; then
        print_success "Worker1 node reachable"
    else
        print_error "Cannot connect to worker1 node"
        exit 1
    fi
    
    print_info "Testing SSH connectivity to worker2..."
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP "echo 'SSH OK'" &> /dev/null; then
        print_success "Worker2 node reachable"
    else
        print_error "Cannot connect to worker2 node"
        exit 1
    fi
}

# Install containerd and Kubernetes tools on a node
install_k8s_on_node() {
    local NODE_IP=$1
    local NODE_NAME=$2
    
    print_info "Installing Kubernetes on $NODE_NAME..."
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$NODE_IP << 'ENDSSH'
        set -e
        
        # Check if already installed
        if command -v kubeadm &> /dev/null; then
            echo "Kubernetes tools already installed, skipping..."
            exit 0
        fi
        
        echo "📦 Step 1: Updating system..."
        sudo apt-get update -qq
        
        echo "📦 Step 2: Installing prerequisites..."
        sudo apt-get install -y -qq apt-transport-https ca-certificates curl gpg
        
        echo "📦 Step 3: Disabling swap..."
        sudo swapoff -a
        sudo sed -i '/ swap / s/^/#/' /etc/fstab
        
        echo "📦 Step 4: Loading kernel modules..."
        cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
        sudo modprobe overlay
        sudo modprobe br_netfilter
        
        echo "📦 Step 5: Setting sysctl parameters..."
        cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
        sudo sysctl --system > /dev/null 2>&1
        
        echo "📦 Step 6: Installing containerd..."
        sudo apt-get install -y -qq containerd
        
        echo "📦 Step 7: Configuring containerd..."
        sudo mkdir -p /etc/containerd
        containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
        sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        sudo systemctl restart containerd
        sudo systemctl enable containerd > /dev/null 2>&1
        
        echo "📦 Step 8: Adding Kubernetes apt repository..."
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
        
        echo "📦 Step 9: Installing kubeadm, kubelet, kubectl..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq kubelet kubeadm kubectl
        sudo apt-mark hold kubelet kubeadm kubectl
        
        echo "✅ Kubernetes installation complete!"
ENDSSH
    
    print_success "$NODE_NAME configured"
}

# Install Kubernetes on all nodes
install_k8s_all_nodes() {
    print_header "Installing Kubernetes on All Nodes"
    
    install_k8s_on_node $MASTER_PUBLIC_IP "Master"
    install_k8s_on_node $WORKER1_PUBLIC_IP "Worker1"
    install_k8s_on_node $WORKER2_PUBLIC_IP "Worker2"
    
    print_success "Kubernetes installed on all nodes"
}

# Initialize Kubernetes master
initialize_master() {
    print_header "Initializing Kubernetes Master Node"
    
    # Check if already initialized
    print_info "Checking if cluster is already initialized..."
    CLUSTER_EXISTS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "sudo kubectl get nodes 2>/dev/null | wc -l" || echo "0")
    
    if [ "$CLUSTER_EXISTS" -gt "1" ]; then
        print_warning "Cluster already initialized, skipping..."
        
        # Get existing join command
        print_info "Retrieving existing join command..."
        K8S_JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
            "sudo kubeadm token create --print-join-command 2>/dev/null")
        
        if [ -z "$K8S_JOIN_COMMAND" ]; then
            print_error "Failed to retrieve join command"
            exit 1
        fi
        
        print_success "Join command retrieved"
    else
        print_info "Initializing new cluster on master node..."
        
        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << ENDSSH
            set -e
            
            echo "🚀 Initializing Kubernetes cluster..."
            sudo kubeadm init --pod-network-cidr=$POD_CIDR --ignore-preflight-errors=NumCPU 2>&1 | tee /tmp/kubeadm-init.log
            
            echo "📋 Setting up kubectl for ubuntu user..."
            mkdir -p \$HOME/.kube
            sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config
            sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
            
            echo "✅ Master initialization complete!"
ENDSSH
        
        print_success "Master node initialized"
        
        # Retrieve join command
        print_info "Retrieving join command..."
        K8S_JOIN_COMMAND=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
            "sudo kubeadm token create --print-join-command 2>/dev/null")
        
        if [ -z "$K8S_JOIN_COMMAND" ]; then
            print_error "Failed to retrieve join command"
            exit 1
        fi
        
        print_success "Join command retrieved"
    fi
    
    # Save join command to deployment-info.txt
    if grep -q "K8S_JOIN_COMMAND=" deployment-info.txt; then
        sed -i "s|^export K8S_JOIN_COMMAND=.*|export K8S_JOIN_COMMAND=\"$K8S_JOIN_COMMAND\"|" deployment-info.txt
    else
        echo "export K8S_JOIN_COMMAND=\"$K8S_JOIN_COMMAND\"" >> deployment-info.txt
    fi
    
    print_info "Join command saved to deployment-info.txt"
}

# Install Calico CNI
install_calico() {
    print_header "Installing Calico CNI Plugin"
    
    # Check if Calico is already installed
    print_info "Checking if Calico is already installed..."
    CALICO_INSTALLED=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "kubectl get pods -n kube-system 2>/dev/null | grep -c calico || echo 0")
    
    if [ "$CALICO_INSTALLED" -gt "0" ]; then
        print_warning "Calico already installed, skipping..."
        return
    fi
    
    print_info "Installing Calico CNI..."
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << ENDSSH
        set -e
        
        echo "📥 Downloading Calico manifest..."
        curl -sL https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml -o /tmp/calico.yaml
        
        echo "🔧 Applying Calico manifest..."
        kubectl apply -f /tmp/calico.yaml
        
        echo "✅ Calico installation initiated!"
ENDSSH
    
    print_success "Calico CNI installed"
    
    # Wait for Calico pods to be ready
    print_info "Waiting for Calico pods to be ready (this may take 1-2 minutes)..."
    sleep 30
    
    ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP << 'ENDSSH'
        echo "Waiting for Calico pods..."
        kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=180s 2>/dev/null || true
        kubectl wait --for=condition=ready pod -l k8s-app=calico-kube-controllers -n kube-system --timeout=180s 2>/dev/null || true
ENDSSH
    
    print_success "Calico is ready"
}

# Join worker nodes to cluster
join_workers() {
    print_header "Joining Worker Nodes to Cluster"
    
    # Check Worker1
    print_info "Checking Worker1 status..."
    WORKER1_JOINED=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "kubectl get nodes 2>/dev/null | grep -c worker1 || echo 0")
    
    if [ "$WORKER1_JOINED" -eq "0" ]; then
        print_info "Joining Worker1 to cluster..."
        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER1_PUBLIC_IP << ENDSSH
            sudo $K8S_JOIN_COMMAND
ENDSSH
        print_success "Worker1 joined"
    else
        print_warning "Worker1 already joined, skipping..."
    fi
    
    # Check Worker2
    print_info "Checking Worker2 status..."
    WORKER2_JOINED=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "kubectl get nodes 2>/dev/null | grep -c worker2 || echo 0")
    
    if [ "$WORKER2_JOINED" -eq "0" ]; then
        print_info "Joining Worker2 to cluster..."
        ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$WORKER2_PUBLIC_IP << ENDSSH
            sudo $K8S_JOIN_COMMAND
ENDSSH
        print_success "Worker2 joined"
    else
        print_warning "Worker2 already joined, skipping..."
    fi
    
    print_success "All workers joined"
}

# Verify cluster health
verify_cluster() {
    print_header "Verifying Cluster Health"
    
    print_info "Waiting for all nodes to be ready (may take 1-2 minutes)..."
    sleep 30
    
    # Get cluster status
    print_info "Checking node status..."
    NODE_STATUS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "kubectl get nodes")
    
    echo "$NODE_STATUS"
    
    # Count ready nodes
    READY_NODES=$(echo "$NODE_STATUS" | grep -c "Ready" || echo "0")
    
    if [ "$READY_NODES" -ge "3" ]; then
        print_success "All 3 nodes are Ready!"
    else
        print_warning "Only $READY_NODES nodes are Ready. Waiting longer..."
        sleep 30
        NODE_STATUS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "kubectl get nodes")
        echo "$NODE_STATUS"
    fi
    
    # Check system pods
    print_info "Checking system pods..."
    SYSTEM_PODS=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "kubectl get pods -n kube-system")
    echo "$SYSTEM_PODS"
    
    print_success "Cluster verification complete"
}

# Save cluster information
save_cluster_info() {
    print_header "Saving Cluster Information"
    
    # Get cluster info
    K8S_CLUSTER_IP=$(ssh -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP \
        "kubectl cluster-info | grep 'Kubernetes control plane' | awk '{print \$NF}'")
    
    # Update deployment-info.txt
    if grep -q "K8S_CLUSTER_IP=" deployment-info.txt; then
        sed -i "s|^export K8S_CLUSTER_IP=.*|export K8S_CLUSTER_IP=\"$K8S_CLUSTER_IP\"|" deployment-info.txt
    else
        echo "export K8S_CLUSTER_IP=\"$K8S_CLUSTER_IP\"" >> deployment-info.txt
    fi
    
    if grep -q "K8S_POD_CIDR=" deployment-info.txt; then
        sed -i "s|^export K8S_POD_CIDR=.*|export K8S_POD_CIDR=\"$POD_CIDR\"|" deployment-info.txt
    else
        echo "export K8S_POD_CIDR=\"$POD_CIDR\"" >> deployment-info.txt
    fi
    
    if grep -q "K8S_VERSION=" deployment-info.txt; then
        sed -i "s|^export K8S_VERSION=.*|export K8S_VERSION=\"$K8S_VERSION\"|" deployment-info.txt
    else
        echo "export K8S_VERSION=\"$K8S_VERSION\"" >> deployment-info.txt
    fi
    
    print_success "Cluster info saved to deployment-info.txt"
}

# Summary
print_summary() {
    print_header "Kubernetes Cluster Setup Summary"
    
    echo -e "${GREEN}✅ Cluster initialized successfully!${NC}"
    echo ""
    echo -e "${BLUE}Cluster Details:${NC}"
    echo "  📍 Kubernetes Version: $K8S_VERSION"
    echo "  🌐 Pod Network CIDR: $POD_CIDR"
    echo "  🔌 CNI Plugin: Calico $CALICO_VERSION"
    echo "  🖥️  Master Node: $MASTER_PUBLIC_IP"
    echo "  👷 Worker1 Node: $WORKER1_PUBLIC_IP"
    echo "  👷 Worker2 Node: $WORKER2_PUBLIC_IP"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "1. Access cluster: ssh -i $KEY_FILE ubuntu@$MASTER_PUBLIC_IP"
    echo "2. Check nodes: kubectl get nodes"
    echo "3. Check pods: kubectl get pods -A"
    echo "4. Deploy sample app (Chat 3): Deploy retail store application"
    echo ""
    echo -e "${YELLOW}Helpful Commands:${NC}"
    echo "  • View cluster: kubectl cluster-info"
    echo "  • View nodes: kubectl get nodes -o wide"
    echo "  • View system pods: kubectl get pods -n kube-system"
    echo "  • Describe node: kubectl describe node <node-name>"
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║   Kubernetes Cluster Initialization           ║"
    echo "║   Chat 2: kubeadm + Calico CNI Setup          ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_prerequisites
    install_k8s_all_nodes
    initialize_master
    install_calico
    join_workers
    verify_cluster
    save_cluster_info
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║    Kubernetes Cluster Setup Complete! 🎉     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
