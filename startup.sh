#!/bin/bash

################################################################################
# Retail Store Kubernetes - Startup Script
# This script starts stopped EC2 instances, captures new IPs, and updates
# deployment-info.txt with current values.
#
# Usage: ./startup.sh
#
# This script is safe to run at any stage - it will only act on resources
# that actually exist.
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
echo "║     Kubernetes Project - Startup Script          ║"
echo "║                                                   ║"
echo "║     Starts stopped resources & updates IPs       ║"
echo "╚═══════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check if deployment-info.txt exists
if [ ! -f "$DEPLOYMENT_INFO" ]; then
    print_warning "deployment-info.txt not found!"
    print_info "This appears to be first run - deployment file will be created during setup."
    print_info "Continuing with default configuration..."
    echo ""
    
    # Create deployment-info.txt if it doesn't exist
    if [ ! -f "$DEPLOYMENT_INFO" ]; then
        print_info "Creating deployment-info.txt template..."
        cat > "$DEPLOYMENT_INFO" << 'EOF'
# Kubernetes kubeadm Cluster Project - Deployment Information
# Source this file to restore variables: source deployment-info.txt

export AWS_REGION="us-east-1"
export PROJECT_NAME="retail-store-k8s"
export KEY_NAME="${PROJECT_NAME}-key"

# EC2 Instance IDs
export MASTER_INSTANCE_ID=""
export WORKER1_INSTANCE_ID=""
export WORKER2_INSTANCE_ID=""

# EC2 Public IPs
export MASTER_IP=""
export WORKER1_IP=""
export WORKER2_IP=""

# Security Group
export SECURITY_GROUP_ID=""
export SECURITY_GROUP_NAME="${PROJECT_NAME}-sg"

# IAM
export IAM_ROLE_NAME="${PROJECT_NAME}-ec2-role"
export IAM_ROLE_ARN=""
export INSTANCE_PROFILE_NAME="${PROJECT_NAME}-ec2-profile"
EOF
        print_success "Created deployment-info.txt template"
    fi
fi

# Source current values
source "$DEPLOYMENT_INFO"

# Check AWS CLI
print_header "Checking Prerequisites"
if ! command -v aws &> /dev/null; then
    print_error "AWS CLI not found. Please install it first."
    exit 1
fi
print_success "AWS CLI installed"

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured"
    print_info "Run: aws configure"
    exit 1
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
        # Update existing variable
        sed -i "s/^export ${var_name}=.*/export ${var_name}=\"${escaped_value}\"/" "$DEPLOYMENT_INFO"
    else
        # Add new variable
        echo "export ${var_name}=\"${escaped_value}\"" >> "$DEPLOYMENT_INFO"
    fi
}

# Update AWS Account ID
update_deployment_info "AWS_ACCOUNT_ID" "$AWS_ACCOUNT_ID"

# Calculate ECR registry
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
update_deployment_info "ECR_REGISTRY" "$ECR_REGISTRY"

# Start EC2 Instances if they exist
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
start_and_update_instance "$MASTER_INSTANCE_ID" "Master Node" "MASTER_IP"
start_and_update_instance "$WORKER1_INSTANCE_ID" "Worker Node 1" "WORKER1_IP"
start_and_update_instance "$WORKER2_INSTANCE_ID" "Worker Node 2" "WORKER2_IP"

if [ $INSTANCES_STARTED -eq 0 ] && [ $INSTANCES_UPDATED -eq 0 ]; then
    print_info "No EC2 instances found to start or update"
    print_info "This is normal if you haven't created instances yet"
fi

# Summary
print_header "Startup Summary"

if [ $INSTANCES_STARTED -gt 0 ]; then
    echo -e "${GREEN}✓ Instances started: $INSTANCES_STARTED${NC}"
fi

if [ $INSTANCES_UPDATED -gt 0 ]; then
    echo -e "${GREEN}✓ IPs updated: $INSTANCES_UPDATED${NC}"
    echo ""
    echo -e "${BLUE}Current IPs:${NC}"
    
    source "$DEPLOYMENT_INFO"
    
    [ -n "$MASTER_IP" ] && echo "  Master:  $MASTER_IP"
    [ -n "$WORKER1_IP" ] && echo "  Worker1: $WORKER1_IP"
    [ -n "$WORKER2_IP" ] && echo "  Worker2: $WORKER2_IP"
fi

echo ""
echo -e "${BLUE}deployment-info.txt has been updated with current values${NC}"
echo ""
echo -e "${YELLOW}To load these variables into your current terminal session:${NC}"
echo -e "  ${CYAN}source deployment-info.txt${NC}"
echo -e "  ${CYAN}# or use the restore script:${NC}"
echo -e "  ${CYAN}source restore-vars.sh${NC}"
echo ""

# Check for SSH key
if [ -n "$KEY_NAME" ] && [ -f "${SCRIPT_DIR}/${KEY_NAME}.pem" ]; then
    echo -e "${BLUE}Quick SSH commands:${NC}"
    [ -n "$MASTER_IP" ] && echo -e "  ${CYAN}ssh -i ${KEY_NAME}.pem ubuntu@${MASTER_IP}  # Master${NC}"
    [ -n "$WORKER1_IP" ] && echo -e "  ${CYAN}ssh -i ${KEY_NAME}.pem ubuntu@${WORKER1_IP}  # Worker1${NC}"
    [ -n "$WORKER2_IP" ] && echo -e "  ${CYAN}ssh -i ${KEY_NAME}.pem ubuntu@${WORKER2_IP}  # Worker2${NC}"
    echo ""
fi

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Startup Complete!                           ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}\n"

echo -e "${YELLOW}To load variables into your current terminal:${NC}"
echo -e "  ${CYAN}source deployment-info.txt${NC}"
echo -e "  ${CYAN}# or${NC}"
echo -e "  ${CYAN}source restore-vars.sh${NC}"
echo ""
```
