#!/bin/bash

################################################################################
# Retail Store Kubernetes - ULTIMATE Startup Script
# This script does EVERYTHING:
#   - Starts stopped EC2 instances
#   - Updates IPs in deployment-info.txt
#   - Configures kubectl with new master IP
#   - Updates ArgoCD and App URLs
#   - Exports ALL variables to current session
#
# Usage: source startup.sh
#        (Use 'source' so variables are exported to YOUR terminal!)
#
################################################################################

set +e  # Don't exit on errors - we check each step

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Helper functions
print_header() {
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ $1${NC}"
}

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOYMENT_INFO="${SCRIPT_DIR}/deployment-info.txt"

# Main header
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════╗"
echo "║   ULTIMATE Startup Script - Does EVERYTHING!     ║"
echo "║                                                   ║"
echo "║   ✓ Start EC2 instances                          ║"
echo "║   ✓ Update IPs                                   ║"
echo "║   ✓ Configure kubectl                            ║"
echo "║   ✓ Export ALL variables                         ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check if deployment-info.txt exists
if [ ! -f "$DEPLOYMENT_INFO" ]; then
    print_error "deployment-info.txt not found!"
    print_info "Please run 01-infrastructure.sh first"
    return 1 2>/dev/null || exit 1
fi

# Source current values
source "$DEPLOYMENT_INFO"

# Check AWS CLI
print_header "Checking Prerequisites"
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not found. Please install it first."
    return 1 2>/dev/null || exit 1
fi
print_success "AWS CLI installed"

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured"
    print_info "Run: aws configure"
    return 1 2>/dev/null || exit 1
fi
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
print_success "AWS credentials configured (Account: $AWS_ACCOUNT_ID)"

# Function to update variable in deployment-info.txt
update_deployment_info() {
    local var_name=$1
    local var_value=$2

    # Escape special characters for sed
    local escaped_value=$(echo "$var_value" | sed 's/[\/&]/\\&/g')

    # Update or add the variable
    if grep -q "^export ${var_name}=" "$DEPLOYMENT_INFO"; then
        sed -i "s/^export ${var_name}=.*/export ${var_name}=\"${escaped_value}\"/" "$DEPLOYMENT_INFO"
    else
        echo "export ${var_name}=\"${escaped_value}\"" >> "$DEPLOYMENT_INFO"
    fi
}

# Update AWS Account ID
update_deployment_info "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"

# Calculate ECR registry
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
update_deployment_info "ECR_REGISTRY" "$ECR_REGISTRY"

# Start EC2 Instances
print_header "Starting EC2 Instances"

INSTANCES_STARTED=0
INSTANCES_UPDATED=0

# Function to start and update instance
start_and_update_instance() {
    local instance_id=$1
    local instance_name=$2
    local ip_var_name=$3

    if [ -z "$instance_id" ]; then
        print_info "$instance_name: No instance ID configured yet"
        return
    fi

    # Check if instance exists
    if ! aws ec2 describe-instances --instance-ids "$instance_id" &>/dev/null; then
        print_warning "$instance_name: Instance $instance_id not found in AWS"
        return
    fi

    # Get current state
    INSTANCE_STATE=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null)

    if [ "$INSTANCE_STATE" = "stopped" ]; then
        print_info "$instance_name: Starting instance $instance_id..."
        aws ec2 start-instances --instance-ids "$instance_id" &>/dev/null

        print_info "$instance_name: Waiting for instance to start..."
        aws ec2 wait instance-running --instance-ids "$instance_id"
        INSTANCES_STARTED=$((INSTANCES_STARTED + 1))
        print_success "$instance_name: Instance started"

        # Small delay to ensure IP is assigned
        sleep 3
    elif [ "$INSTANCE_STATE" = "running" ]; then
        print_success "$instance_name: Already running"
    elif [ "$INSTANCE_STATE" = "pending" ]; then
        print_info "$instance_name: Instance is starting..."
        aws ec2 wait instance-running --instance-ids "$instance_id"
        print_success "$instance_name: Instance running"
    else
        print_warning "$instance_name: Instance in state: $INSTANCE_STATE"
    fi

    # Get new public IP
    NEW_IP=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text 2>/dev/null)

    if [ -n "$NEW_IP" ] && [ "$NEW_IP" != "None" ]; then
        print_info "$instance_name: New IP: $NEW_IP"
        update_deployment_info "$ip_var_name" "$NEW_IP"
        INSTANCES_UPDATED=$((INSTANCES_UPDATED + 1))

        # Export to current session
        export "$ip_var_name"="$NEW_IP"
    else
        print_warning "$instance_name: No public IP assigned"
    fi
}

# Start and update all instances
start_and_update_instance "$MASTER_INSTANCE_ID" "Master Node" "MASTER_PUBLIC_IP"
start_and_update_instance "$WORKER1_INSTANCE_ID" "Worker Node 1" "WORKER1_PUBLIC_IP"
start_and_update_instance "$WORKER2_INSTANCE_ID" "Worker Node 2" "WORKER2_PUBLIC_IP"

# Configure kubectl
print_header "Configuring kubectl"

if [ -n "$MASTER_PUBLIC_IP" ] && [ -f "$KEY_FILE" ]; then
    print_info "Copying kubeconfig from master node..."
    mkdir -p ~/.kube

    # Give SSH daemon time to start if instance just started
    if [ $INSTANCES_STARTED -gt 0 ]; then
        print_info "Waiting for SSH to be ready..."
        sleep 10
    fi

    # Copy kubeconfig
    if scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 -i "$KEY_FILE" \
        ubuntu@$MASTER_PUBLIC_IP:~/.kube/config ~/.kube/config-haddar-retail-store 2>/dev/null; then

        print_success "Kubeconfig copied"

        # Update server URL with new master IP
        sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|g" ~/.kube/config-haddar-retail-store

        # Remove certificate-authority-data and add insecure-skip-tls-verify
        sed -i '/certificate-authority-data:/d' ~/.kube/config-haddar-retail-store
        sed -i '/server: https/a\    insecure-skip-tls-verify: true' ~/.kube/config-haddar-retail-store

        # Export KUBECONFIG for current session
        export KUBECONFIG=~/.kube/config-haddar-retail-store

        print_success "kubectl configured with new master IP"
        print_success "KUBECONFIG exported to current session"

        # Test kubectl
        if kubectl get nodes &>/dev/null; then
            print_success "kubectl connection verified"
            kubectl get nodes
        else
            print_warning "kubectl configured but cluster may still be initializing"
        fi
    else
        print_warning "Could not copy kubeconfig (cluster may not be initialized yet)"
    fi
else
    print_info "Skipping kubectl config (master IP or key file not available)"
fi

# Update ArgoCD URL
if [ -n "$MASTER_PUBLIC_IP" ]; then
    ARGOCD_URL="https://${MASTER_PUBLIC_IP}:30090"
    update_deployment_info "ARGOCD_URL" "$ARGOCD_URL"
    export ARGOCD_URL
    print_success "ArgoCD URL updated: $ARGOCD_URL"
fi

# Update App URL
if [ -n "$MASTER_PUBLIC_IP" ]; then
    APP_URL="http://${MASTER_PUBLIC_IP}:30080"
    update_deployment_info "APP_URL" "$APP_URL"
    export APP_URL
    print_success "App URL updated: $APP_URL"
fi

# Re-source deployment-info.txt to load ALL variables into current session
print_header "Loading ALL Variables"
source "$DEPLOYMENT_INFO"
print_success "All variables loaded into current session"

# Also update restore-vars.sh to include KUBECONFIG
if [ -f "${SCRIPT_DIR}/restore-vars.sh" ]; then
    # Check if KUBECONFIG is already in restore-vars.sh
    if ! grep -q "export KUBECONFIG=" "${SCRIPT_DIR}/restore-vars.sh"; then
        echo "" >> "${SCRIPT_DIR}/restore-vars.sh"
        echo "# kubectl configuration" >> "${SCRIPT_DIR}/restore-vars.sh"
        echo "export KUBECONFIG=~/.kube/config-haddar-retail-store" >> "${SCRIPT_DIR}/restore-vars.sh"
        print_success "Added KUBECONFIG to restore-vars.sh"
    fi
fi

# Summary
print_header "Startup Complete! 🎉"

if [ $INSTANCES_STARTED -gt 0 ]; then
    echo -e "${GREEN}✓ Instances started: $INSTANCES_STARTED${NC}"
fi

if [ $INSTANCES_UPDATED -gt 0 ]; then
    echo -e "${GREEN}✓ IPs updated: $INSTANCES_UPDATED${NC}"
fi

echo ""
echo -e "${BLUE}Current Environment:${NC}"
[ -n "$MASTER_PUBLIC_IP" ] && echo -e "  Master IP:   ${CYAN}$MASTER_PUBLIC_IP${NC}"
[ -n "$WORKER1_PUBLIC_IP" ] && echo -e "  Worker1 IP:  ${CYAN}$WORKER1_PUBLIC_IP${NC}"
[ -n "$WORKER2_PUBLIC_IP" ] && echo -e "  Worker2 IP:  ${CYAN}$WORKER2_PUBLIC_IP${NC}"
[ -n "$APP_URL" ] && echo -e "  App URL:     ${CYAN}$APP_URL${NC}"
[ -n "$ARGOCD_URL" ] && echo -e "  ArgoCD URL:  ${CYAN}$ARGOCD_URL${NC}"
[ -n "$KUBECONFIG" ] && echo -e "  KUBECONFIG:  ${CYAN}$KUBECONFIG${NC}"

echo ""
echo -e "${GREEN}✅ ALL VARIABLES EXPORTED TO CURRENT SESSION!${NC}"
echo -e "${GREEN}✅ kubectl IS READY TO USE!${NC}"
echo ""

if [ -n "$MASTER_PUBLIC_IP" ] && [ -f "$KEY_FILE" ]; then
    echo -e "${BLUE}Quick Commands:${NC}"
    echo -e "  ${CYAN}kubectl get nodes${NC}                       # Check cluster"
    echo -e "  ${CYAN}kubectl get pods -n retail-store${NC}        # Check apps"
    echo -e "  ${CYAN}ssh -i $KEY_NAME.pem ubuntu@$MASTER_PUBLIC_IP${NC}  # SSH to master"
    echo ""
fi

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   You're Ready To Work! Everything Loaded!    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}\n"