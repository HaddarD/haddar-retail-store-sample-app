#!/bin/bash

################################################################################
# Terraform Bootstrap Script
# Creates S3 bucket for remote state storage and initializes Terraform
#
# This script:
# 1. Creates S3 bucket for Terraform state
# 2. Enables versioning on the bucket
# 3. Creates DynamoDB table for state locking
# 4. Comments out backend config in main.tf (for first run)
# 5. Runs terraform init
# 6. Uncomments backend config
# 7. Migrates state to S3
################################################################################

set -e  # Exit on any error

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TERRAFORM_DIR="${SCRIPT_DIR}/terraform"

# Configuration
BUCKET_NAME="haddar-k8s-terraform-state"
DYNAMODB_TABLE="terraform-state-lock"
REGION="us-east-1"

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
echo "║   Terraform Bootstrap - S3 Backend Setup             ║"
echo "║   Phase 1: Initialize Remote State Storage           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install it first."
        exit 1
    fi
    print_success "AWS CLI installed"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS credentials configured (Account: ${AWS_ACCOUNT_ID})"
    
    # Check Terraform
    if ! command -v terraform &> /dev/null; then
        print_error "Terraform not found. Please install Terraform first."
        print_info "Visit: https://www.terraform.io/downloads"
        exit 1
    fi
    TERRAFORM_VERSION=$(terraform --version | head -n 1)
    print_success "${TERRAFORM_VERSION}"
    
    # Check terraform directory
    if [ ! -d "$TERRAFORM_DIR" ]; then
        print_error "Terraform directory not found: $TERRAFORM_DIR"
        exit 1
    fi
    print_success "Terraform directory found"
    
    # Check SSH key pair exists
    if [ ! -f "${SCRIPT_DIR}/haddar-k8s-kubeadm-key" ]; then
        print_error "SSH key pair not found: haddar-k8s-kubeadm-key"
        print_info "Generate with: ssh-keygen -t rsa -b 4096 -f haddar-k8s-kubeadm-key -N \"\""
        exit 1
    fi
    print_success "SSH key pair found"
}

# Create S3 bucket for state
create_s3_bucket() {
    print_header "Creating S3 Bucket for Terraform State"
    
    # Check if bucket already exists
    if aws s3 ls "s3://${BUCKET_NAME}" 2>/dev/null; then
        print_warning "S3 bucket already exists: ${BUCKET_NAME}"
        print_info "Using existing bucket"
    else
        print_info "Creating S3 bucket: ${BUCKET_NAME}..."
        aws s3 mb "s3://${BUCKET_NAME}" --region "${REGION}"
        print_success "S3 bucket created"
        
        # Wait for bucket to be available
        sleep 2
    fi
    
    # Enable versioning
    print_info "Enabling versioning on S3 bucket..."
    aws s3api put-bucket-versioning \
        --bucket "${BUCKET_NAME}" \
        --versioning-configuration Status=Enabled \
        --region "${REGION}"
    print_success "Versioning enabled"
    
    # Enable encryption
    print_info "Enabling encryption on S3 bucket..."
    aws s3api put-bucket-encryption \
        --bucket "${BUCKET_NAME}" \
        --server-side-encryption-configuration '{
            "Rules": [{
                "ApplyServerSideEncryptionByDefault": {
                    "SSEAlgorithm": "AES256"
                }
            }]
        }' \
        --region "${REGION}"
    print_success "Encryption enabled"
    
    # Block public access
    print_info "Blocking public access..."
    aws s3api put-public-access-block \
        --bucket "${BUCKET_NAME}" \
        --public-access-block-configuration \
            "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
        --region "${REGION}"
    print_success "Public access blocked"
}

# Create DynamoDB table for state locking
create_dynamodb_table() {
    print_header "Creating DynamoDB Table for State Locking"
    
    # Check if table already exists
    if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" &>/dev/null; then
        print_warning "DynamoDB table already exists: ${DYNAMODB_TABLE}"
        print_info "Using existing table"
    else
        print_info "Creating DynamoDB table: ${DYNAMODB_TABLE}..."
        aws dynamodb create-table \
            --table-name "${DYNAMODB_TABLE}" \
            --attribute-definitions AttributeName=LockID,AttributeType=S \
            --key-schema AttributeName=LockID,KeyType=HASH \
            --billing-mode PAY_PER_REQUEST \
            --region "${REGION}" \
            --tags Key=Project,Value=haddar-k8s-kubeadm Key=ManagedBy,Value=Terraform \
            > /dev/null
        
        print_info "Waiting for table to be active..."
        aws dynamodb wait table-exists --table-name "${DYNAMODB_TABLE}" --region "${REGION}"
        print_success "DynamoDB table created"
    fi
}

# Initialize Terraform (first run without backend)
initialize_terraform() {
    print_header "Initializing Terraform"
    
    cd "$TERRAFORM_DIR"
    
    # Check if backend is already configured
    if grep -q "^\s*backend\s*\"s3\"" main.tf && ! grep -q "^\s*#.*backend\s*\"s3\"" main.tf; then
        print_info "Backend already configured in main.tf"
        print_info "Initializing with S3 backend..."
        terraform init -reconfigure
        print_success "Terraform initialized with S3 backend"
    else
        print_info "Backend not yet configured"
        print_info "Running initial terraform init..."
        terraform init
        print_success "Terraform initialized (local state)"
        
        # Now configure backend and migrate
        print_info "Configuring S3 backend..."
        print_warning "You may be prompted to migrate state to S3"
        terraform init -migrate-state -force-copy
        print_success "State migrated to S3 backend"
    fi
    
    cd "$SCRIPT_DIR"
}

# Verify setup
verify_setup() {
    print_header "Verifying Setup"
    
    # Check S3 bucket
    if aws s3 ls "s3://${BUCKET_NAME}" --region "${REGION}" &>/dev/null; then
        print_success "S3 bucket accessible"
    else
        print_error "Cannot access S3 bucket"
        exit 1
    fi
    
    # Check DynamoDB table
    if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE}" --region "${REGION}" &>/dev/null; then
        print_success "DynamoDB table accessible"
    else
        print_error "Cannot access DynamoDB table"
        exit 1
    fi
    
    # Check Terraform initialization
    if [ -d "${TERRAFORM_DIR}/.terraform" ]; then
        print_success "Terraform initialized"
    else
        print_error "Terraform not initialized properly"
        exit 1
    fi
}

# Print summary
print_summary() {
    print_header "Bootstrap Complete!"
    
    echo -e "${GREEN}✅ Terraform backend configured successfully!${NC}"
    echo ""
    echo -e "${BLUE}S3 Backend:${NC}"
    echo -e "  Bucket:        ${CYAN}${BUCKET_NAME}${NC}"
    echo -e "  Region:        ${CYAN}${REGION}${NC}"
    echo -e "  State Key:     ${CYAN}kubernetes/terraform.tfstate${NC}"
    echo -e "  Lock Table:    ${CYAN}${DYNAMODB_TABLE}${NC}"
    echo ""
    echo -e "${BLUE}Features:${NC}"
    echo -e "  ${GREEN}✓${NC} Versioning enabled (state history)"
    echo -e "  ${GREEN}✓${NC} Encryption enabled (AES256)"
    echo -e "  ${GREEN}✓${NC} Public access blocked"
    echo -e "  ${GREEN}✓${NC} State locking enabled"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo -e "  1. Review terraform configuration: ${CYAN}cd terraform && terraform plan${NC}"
    echo -e "  2. Create all infrastructure:      ${CYAN}./02-terraform-apply.sh${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  • Terraform state is now stored remotely in S3"
    echo "  • State is encrypted and versioned"
    echo "  • Multiple people can work on this infrastructure safely"
    echo "  • State locking prevents concurrent modifications"
}

# Main execution
main() {
    check_prerequisites
    create_s3_bucket
    create_dynamodb_table
    initialize_terraform
    verify_setup
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Terraform Bootstrap Completed Successfully! 🎉    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
