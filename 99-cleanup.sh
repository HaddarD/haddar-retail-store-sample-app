#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Complete Cleanup Script
# This script removes ALL AWS resources and Kubernetes deployments:
# - Helm releases (applications + dependencies)
# - Kubernetes namespace
# - DynamoDB table
# - EC2 instances (master + 2 workers)
# - Security group
# - IAM role and instance profile
# - SSH key pair (from AWS, keeps local file)
# - ECR repositories
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
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

# Check if deployment-info.txt exists
if [ ! -f "deployment-info.txt" ]; then
    print_error "deployment-info.txt not found!"
    print_info "Nothing to clean up or file was already deleted"
    exit 1
fi

# Load variables
source deployment-info.txt

# Configuration
NAMESPACE="${NAMESPACE:-retail-store}"
ECR_REPOSITORIES=(
    "retail-store-ui"
    "retail-store-catalog"
    "retail-store-cart"
    "retail-store-orders"
    "retail-store-checkout"
)

# Warning message
echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║              ⚠️  WARNING: CLEANUP SCRIPT  ⚠️           ║"
echo "║                                                       ║"
echo "║  This will DELETE all AWS resources and              ║"
echo "║  Kubernetes deployments created by this project:     ║"
echo "║                                                       ║"
echo "║  KUBERNETES:                                         ║"
echo "║  • All Helm releases (retail-store, postgres, etc)   ║"
echo "║  • Namespace: ${NAMESPACE}                          ║"
echo "║                                                       ║"
echo "║  AWS RESOURCES:                                      ║"
echo "║  • 3 EC2 Instances (master + 2 workers)              ║"
echo "║  • DynamoDB Table: ${DYNAMODB_TABLE_NAME:-retail-store-cart}            ║"
echo "║  • Security Group: ${SECURITY_GROUP_NAME}                    ║"
echo "║  • IAM Role: ${IAM_ROLE_NAME}              ║"
echo "║  • IAM Instance Profile: ${IAM_INSTANCE_PROFILE_NAME}     ║"
echo "║  • SSH Key Pair from AWS                             ║"
echo "║  • 5 ECR Repositories (and all images)               ║"
echo "║                                                       ║"
echo "║  ⚠️  This action CANNOT be undone!                    ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

echo -n "Are you ABSOLUTELY SURE you want to delete everything? (type 'DELETE' to confirm): "
read -r confirmation

if [ "$confirmation" != "DELETE" ]; then
    echo -e "\n${GREEN}Cleanup cancelled.${NC}\n"
    exit 0
fi

echo -e "\n${YELLOW}Starting cleanup in 5 seconds... Press Ctrl+C to cancel${NC}"
sleep 5

# Cleanup Helm releases and Kubernetes resources
print_header "Step 1: Cleaning Up Helm Releases & Kubernetes"

# Check if Helm is installed
if command -v helm &> /dev/null; then
    # Check if kubeconfig exists
    if [ -f ~/.kube/config-retail-store ]; then
        export KUBECONFIG=~/.kube/config-retail-store
        print_info "Using kubeconfig: ~/.kube/config-retail-store"
        
        # Set insecure skip TLS verify
        kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true 2>/dev/null
    fi
    
    # Check if kubectl can connect
    if kubectl get nodes &> /dev/null 2>&1; then
        print_info "Connected to Kubernetes cluster"
        
        # Uninstall retail store application
        if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "retail-store"; then
            print_info "Uninstalling retail-store Helm release..."
            helm uninstall retail-store -n ${NAMESPACE} --wait --timeout 2m 2>/dev/null || print_warning "Failed to uninstall retail-store"
            print_success "Retail store uninstalled"
        else
            print_info "Retail store not found"
        fi
        
        # Uninstall dependencies
        DEPENDENCIES=("postgresql" "redis" "rabbitmq")
        for dep in "${DEPENDENCIES[@]}"; do
            if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^${dep}"; then
                print_info "Uninstalling ${dep}..."
                helm uninstall ${dep} -n ${NAMESPACE} --wait --timeout 2m 2>/dev/null || print_warning "Failed to uninstall ${dep}"
                print_success "${dep} uninstalled"
            else
                print_info "${dep} not found"
            fi
        done
        
        # Uninstall NGINX Ingress
        if helm list -n ingress-nginx 2>/dev/null | grep -q "ingress-nginx"; then
            print_info "Uninstalling NGINX Ingress Controller..."
            helm uninstall ingress-nginx -n ingress-nginx --wait --timeout 2m 2>/dev/null || print_warning "Failed to uninstall ingress-nginx"
            print_success "NGINX Ingress uninstalled"
        else
            print_info "NGINX Ingress not found"
        fi
        
        # Delete namespaces
        if kubectl get namespace ${NAMESPACE} &> /dev/null 2>&1; then
            print_info "Deleting namespace: ${NAMESPACE}"
            kubectl delete namespace ${NAMESPACE} --wait=false 2>/dev/null || print_warning "Failed to delete namespace"
            print_success "Namespace deletion initiated"
        fi
        
        if kubectl get namespace ingress-nginx &> /dev/null 2>&1; then
            print_info "Deleting namespace: ingress-nginx"
            kubectl delete namespace ingress-nginx --wait=false 2>/dev/null || print_warning "Failed to delete namespace"
            print_success "Ingress namespace deletion initiated"
        fi
        
        print_success "Kubernetes resources cleaned up"
    else
        print_warning "Cannot connect to Kubernetes cluster - skipping Helm cleanup"
        print_info "Cluster may already be destroyed"
    fi
else
    print_warning "Helm not installed - skipping Helm cleanup"
fi

# Delete DynamoDB table
print_header "Step 2: Deleting DynamoDB Table"

if [ -n "$DYNAMODB_TABLE_NAME" ]; then
    DYNAMODB_REGION="${DYNAMODB_REGION:-${REGION}}"
    
    if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE_NAME}" --region ${DYNAMODB_REGION} &> /dev/null; then
        print_info "Deleting DynamoDB table: ${DYNAMODB_TABLE_NAME}"
        aws dynamodb delete-table \
            --table-name "${DYNAMODB_TABLE_NAME}" \
            --region ${DYNAMODB_REGION} > /dev/null
        print_success "DynamoDB table deleted: ${DYNAMODB_TABLE_NAME}"
    else
        print_warning "DynamoDB table not found or already deleted"
    fi
else
    print_info "No DynamoDB table configured"
fi

# Disassociate IAM instance profiles
print_header "Step 3: Disassociating IAM Instance Profiles"

for instance_id in ${MASTER_INSTANCE_ID} ${WORKER1_INSTANCE_ID} ${WORKER2_INSTANCE_ID}; do
    ASSOC_ID=$(aws ec2 describe-iam-instance-profile-associations \
        --filters "Name=instance-id,Values=${instance_id}" \
        --query 'IamInstanceProfileAssociations[0].AssociationId' \
        --output text \
        --region ${REGION} 2>/dev/null)
    
    if [ "$ASSOC_ID" != "None" ] && [ -n "$ASSOC_ID" ]; then
        print_info "Disassociating IAM profile from ${instance_id}..."
        aws ec2 disassociate-iam-instance-profile \
            --association-id ${ASSOC_ID} \
            --region ${REGION} > /dev/null
        print_success "Profile disassociated from ${instance_id}"
    else
        print_info "No IAM profile associated with ${instance_id}"
    fi
done

# Terminate EC2 instances
print_header "Step 4: Terminating EC2 Instances"

print_info "Terminating all instances..."
aws ec2 terminate-instances \
    --instance-ids ${MASTER_INSTANCE_ID} ${WORKER1_INSTANCE_ID} ${WORKER2_INSTANCE_ID} \
    --region ${REGION} > /dev/null

print_success "Termination initiated"

print_info "Waiting for instances to terminate (this may take 1-2 minutes)..."
aws ec2 wait instance-terminated \
    --instance-ids ${MASTER_INSTANCE_ID} ${WORKER1_INSTANCE_ID} ${WORKER2_INSTANCE_ID} \
    --region ${REGION}

print_success "All EC2 instances terminated"

# Delete security group
print_header "Step 5: Deleting Security Group"

print_info "Waiting for network interfaces to detach (10 seconds)..."
sleep 10

if aws ec2 describe-security-groups --group-ids ${SECURITY_GROUP_ID} --region ${REGION} &> /dev/null; then
    print_info "Deleting security group: ${SECURITY_GROUP_ID}"
    aws ec2 delete-security-group \
        --group-id ${SECURITY_GROUP_ID} \
        --region ${REGION}
    print_success "Security group deleted"
else
    print_warning "Security group not found or already deleted"
fi

# Delete IAM resources
print_header "Step 6: Deleting IAM Resources"

# Remove role from instance profile
if aws iam get-instance-profile --instance-profile-name ${IAM_INSTANCE_PROFILE_NAME} &> /dev/null; then
    print_info "Removing role from instance profile..."
    aws iam remove-role-from-instance-profile \
        --instance-profile-name ${IAM_INSTANCE_PROFILE_NAME} \
        --role-name ${IAM_ROLE_NAME} 2>/dev/null || print_info "Role already removed"
    
    print_info "Deleting instance profile..."
    aws iam delete-instance-profile \
        --instance-profile-name ${IAM_INSTANCE_PROFILE_NAME}
    print_success "Instance profile deleted"
else
    print_warning "Instance profile not found or already deleted"
fi

# Delete IAM role
if aws iam get-role --role-name ${IAM_ROLE_NAME} &> /dev/null; then
    # Delete inline policies
    print_info "Deleting inline policies..."
    POLICIES=$(aws iam list-role-policies \
        --role-name ${IAM_ROLE_NAME} \
        --query 'PolicyNames' \
        --output text)
    
    for policy in $POLICIES; do
        aws iam delete-role-policy \
            --role-name ${IAM_ROLE_NAME} \
            --policy-name ${policy}
        print_success "Deleted policy: ${policy}"
    done
    
    # Detach managed policies
    print_info "Detaching managed policies..."
    ATTACHED_POLICIES=$(aws iam list-attached-role-policies \
        --role-name ${IAM_ROLE_NAME} \
        --query 'AttachedPolicies[*].PolicyArn' \
        --output text)
    
    for policy_arn in $ATTACHED_POLICIES; do
        aws iam detach-role-policy \
            --role-name ${IAM_ROLE_NAME} \
            --policy-arn ${policy_arn}
        print_success "Detached policy: ${policy_arn}"
    done
    
    print_info "Deleting IAM role..."
    aws iam delete-role --role-name ${IAM_ROLE_NAME}
    print_success "IAM role deleted: ${IAM_ROLE_NAME}"
else
    print_warning "IAM role not found or already deleted"
fi

# Delete SSH key pair from AWS
print_header "Step 7: Deleting SSH Key Pair from AWS"

if aws ec2 describe-key-pairs --key-names ${KEY_NAME} --region ${REGION} &> /dev/null; then
    print_info "Deleting key pair from AWS: ${KEY_NAME}"
    aws ec2 delete-key-pair --key-name ${KEY_NAME} --region ${REGION}
    print_success "Key pair deleted from AWS"
else
    print_warning "Key pair not found in AWS or already deleted"
fi

# Delete ECR repositories
print_header "Step 8: Deleting ECR Repositories"

ECR_DELETED=0
for REPO_NAME in "${ECR_REPOSITORIES[@]}"; do
    if aws ecr describe-repositories --repository-names "${REPO_NAME}" --region ${REGION} &> /dev/null; then
        print_info "Deleting ECR repository: ${REPO_NAME}"
        
        # Force delete (removes all images)
        aws ecr delete-repository \
            --repository-name "${REPO_NAME}" \
            --region ${REGION} \
            --force > /dev/null
        
        print_success "Deleted: ${REPO_NAME}"
        ECR_DELETED=$((ECR_DELETED + 1))
    else
        print_info "Repository not found: ${REPO_NAME}"
    fi
done

if [ $ECR_DELETED -gt 0 ]; then
    print_success "Deleted ${ECR_DELETED} ECR repositories"
else
    print_warning "No ECR repositories found to delete"
fi

# Clean up local files
print_header "Step 9: Cleaning Up Local Files"

echo -e "${YELLOW}Do you want to delete local files? (deployment-info.txt, SSH key, kubeconfig, etc.)${NC}"
echo -n "Type 'yes' to delete local files, or press Enter to keep them: "
read -r delete_local

if [ "$delete_local" = "yes" ]; then
    print_info "Deleting local files..."
    
    # Delete deployment info
    rm -f deployment-info.txt
    print_success "Deleted: deployment-info.txt"
    
    # Delete SSH key
    if [ -f "${KEY_FILE}" ]; then
        rm -f ${KEY_FILE}
        print_success "Deleted: ${KEY_FILE}"
    fi
    
    # Delete kubeconfig
    if [ -f ~/.kube/config-retail-store ]; then
        rm -f ~/.kube/config-retail-store
        print_success "Deleted: ~/.kube/config-retail-store"
    fi
    
    # Delete temporary files
    rm -f /tmp/ec2-trust-policy.json
    rm -f /tmp/ecr-access-policy.json
    rm -f /tmp/user-data.sh
    rm -f /tmp/master-user-data.sh
    rm -f /tmp/worker1-user-data.sh
    rm -f /tmp/worker2-user-data.sh
    print_success "Deleted: temporary files"
else
    print_info "Keeping local files"
    print_warning "Remember to manually delete sensitive files when done:"
    print_warning "  - ${KEY_FILE} (SSH private key)"
    print_warning "  - deployment-info.txt (contains IPs and IDs)"
    print_warning "  - ~/.kube/config-retail-store (cluster access)"
fi

# Summary
print_header "Cleanup Summary"

echo -e "${GREEN}✓ All AWS resources deleted${NC}"
echo ""
echo -e "${BLUE}Resources Deleted:${NC}"
echo "  • Kubernetes Deployments:"
echo "    - Helm releases (retail-store, postgresql, redis, rabbitmq)"
echo "    - Namespace: ${NAMESPACE}"
echo "    - NGINX Ingress Controller"
echo "  • DynamoDB Table: ${DYNAMODB_TABLE_NAME:-retail-store-cart}"
echo "  • EC2 Instances:"
echo "    - Master:  ${MASTER_INSTANCE_ID}"
echo "    - Worker1: ${WORKER1_INSTANCE_ID}"
echo "    - Worker2: ${WORKER2_INSTANCE_ID}"
echo "  • Security Group: ${SECURITY_GROUP_ID}"
echo "  • IAM Role: ${IAM_ROLE_NAME}"
echo "  • IAM Instance Profile: ${IAM_INSTANCE_PROFILE_NAME}"
echo "  • SSH Key Pair (from AWS): ${KEY_NAME}"

if [ $ECR_DELETED -gt 0 ]; then
    echo "  • ECR Repositories (${ECR_DELETED}):"
    for REPO_NAME in "${ECR_REPOSITORIES[@]}"; do
        echo "    - ${REPO_NAME}"
    done
fi

if [ "$delete_local" = "yes" ]; then
    echo ""
    echo -e "${GREEN}✓ Local files deleted${NC}"
else
    echo ""
    echo -e "${YELLOW}⚠ Local files kept${NC}"
    echo "  • ${KEY_FILE}"
    echo "  • deployment-info.txt"
    echo "  • ~/.kube/config-retail-store"
fi

echo ""
echo -e "${BLUE}What's Remaining:${NC}"
echo "  • Source code files (scripts, helm-chart, etc.)"
echo "  • CloudWatch Logs (will expire automatically)"

if [ "$delete_local" != "yes" ]; then
    echo "  • Local SSH key, deployment info, and kubeconfig (delete manually if needed)"
fi

echo -e "\n${YELLOW}Note: CloudWatch log groups may remain but will expire automatically.${NC}"
echo -e "${YELLOW}You can manually delete them from the AWS Console if needed.${NC}"

echo -e "\n${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Cleanup Completed Successfully!         ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}\n"

echo -e "${BLUE}To recreate the infrastructure, run:${NC}"
echo -e "  ${YELLOW}./01-infrastructure.sh${NC}"
echo -e "  ${YELLOW}./02-k8s-init.sh${NC}"
echo -e "  ${YELLOW}./03-ecr-setup.sh${NC}"
echo -e "  ${YELLOW}./05-dynamodb-setup.sh${NC}"
echo -e "  ${YELLOW}./06-helm-deploy.sh${NC}\n"
