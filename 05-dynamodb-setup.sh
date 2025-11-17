#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - DynamoDB Setup Script
# Chat 4: Create DynamoDB table for Cart service
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
DYNAMODB_TABLE_NAME="retail-store-cart"
DYNAMODB_REGION="${REGION:-us-east-1}"

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
echo "║   Kubernetes kubeadm Cluster - DynamoDB Setup        ║"
echo "║   Phase 4: Cart Service Database                     ║"
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
}

# Create DynamoDB table
create_dynamodb_table() {
    print_header "Creating DynamoDB Table"
    
    print_info "Table Name: ${DYNAMODB_TABLE_NAME}"
    print_info "Region: ${DYNAMODB_REGION}"
    echo ""
    
    # Check if table already exists
    if aws dynamodb describe-table --table-name "${DYNAMODB_TABLE_NAME}" --region ${DYNAMODB_REGION} &> /dev/null; then
        print_warning "DynamoDB table already exists: ${DYNAMODB_TABLE_NAME}"
        
        # Get table status
        TABLE_STATUS=$(aws dynamodb describe-table \
            --table-name "${DYNAMODB_TABLE_NAME}" \
            --region ${DYNAMODB_REGION} \
            --query 'Table.TableStatus' \
            --output text)
        
        print_info "Table Status: ${TABLE_STATUS}"
        
        if [ "$TABLE_STATUS" = "ACTIVE" ]; then
            print_success "Table is active and ready to use"
        else
            print_warning "Table exists but not active yet (status: ${TABLE_STATUS})"
            print_info "Waiting for table to become active..."
            aws dynamodb wait table-exists \
                --table-name "${DYNAMODB_TABLE_NAME}" \
                --region ${DYNAMODB_REGION}
            print_success "Table is now active"
        fi
    else
        print_info "Creating new DynamoDB table..."
        
        # Create table with on-demand billing
        aws dynamodb create-table \
            --table-name "${DYNAMODB_TABLE_NAME}" \
            --attribute-definitions \
                AttributeName=id,AttributeType=S \
                AttributeName=customerId,AttributeType=S \
            --key-schema \
                AttributeName=id,KeyType=HASH \
            --global-secondary-indexes \
                "IndexName=idx_global_customerId,\
KeySchema=[{AttributeName=customerId,KeyType=HASH}],\
Projection={ProjectionType=ALL}" \
            --billing-mode PAY_PER_REQUEST \
            --region ${DYNAMODB_REGION} \
            --tags \
                Key=Project,Value=${PROJECT_NAME} \
                Key=Environment,Value=dev \
                Key=ManagedBy,Value=script \
            > /dev/null
        
        print_success "DynamoDB table creation initiated"
        
        print_info "Waiting for table to become active (this may take 30-60 seconds)..."
        aws dynamodb wait table-exists \
            --table-name "${DYNAMODB_TABLE_NAME}" \
            --region ${DYNAMODB_REGION}
        
        print_success "DynamoDB table is now active!"
    fi
    
    # Get table ARN
    TABLE_ARN=$(aws dynamodb describe-table \
        --table-name "${DYNAMODB_TABLE_NAME}" \
        --region ${DYNAMODB_REGION} \
        --query 'Table.TableArn' \
        --output text)
    
    print_info "Table ARN: ${TABLE_ARN}"
}

# Update deployment-info.txt
update_deployment_info() {
    print_header "Updating deployment-info.txt"
    
    # Add DynamoDB section marker if it doesn't exist
    if ! grep -q "# DynamoDB Configuration" deployment-info.txt; then
        echo "" >> deployment-info.txt
        echo "# DynamoDB Configuration" >> deployment-info.txt
    fi
    
    # Update or add DynamoDB table name
    if grep -q "^export DYNAMODB_TABLE_NAME=" deployment-info.txt; then
        sed -i "s|^export DYNAMODB_TABLE_NAME=.*|export DYNAMODB_TABLE_NAME=\"${DYNAMODB_TABLE_NAME}\"|" deployment-info.txt
    else
        echo "export DYNAMODB_TABLE_NAME=\"${DYNAMODB_TABLE_NAME}\"" >> deployment-info.txt
    fi
    
    # Update or add DynamoDB region
    if grep -q "^export DYNAMODB_REGION=" deployment-info.txt; then
        sed -i "s|^export DYNAMODB_REGION=.*|export DYNAMODB_REGION=\"${DYNAMODB_REGION}\"|" deployment-info.txt
    else
        echo "export DYNAMODB_REGION=\"${DYNAMODB_REGION}\"" >> deployment-info.txt
    fi
    
    # Update or add table ARN
    if grep -q "^export DYNAMODB_TABLE_ARN=" deployment-info.txt; then
        sed -i "s|^export DYNAMODB_TABLE_ARN=.*|export DYNAMODB_TABLE_ARN=\"${TABLE_ARN}\"|" deployment-info.txt
    else
        echo "export DYNAMODB_TABLE_ARN=\"${TABLE_ARN}\"" >> deployment-info.txt
    fi
    
    print_success "deployment-info.txt updated with DynamoDB information"
    print_info "Load variables with: source deployment-info.txt"
}

# Print summary
print_summary() {
    print_header "DynamoDB Setup Complete!"
    
    echo -e "${GREEN}✅ DynamoDB table created successfully!${NC}"
    echo ""
    echo -e "${BLUE}Table Information:${NC}"
    echo -e "  Name:   ${CYAN}${DYNAMODB_TABLE_NAME}${NC}"
    echo -e "  Region: ${CYAN}${DYNAMODB_REGION}${NC}"
    echo -e "  ARN:    ${CYAN}${TABLE_ARN}${NC}"
    echo ""
    echo -e "${BLUE}Table Schema:${NC}"
    echo "  • Primary Key: id (String)"
    echo "  • Global Secondary Index: idx_global_customerId"
    echo "    - Key: customerId (String)"
    echo "  • Billing Mode: PAY_PER_REQUEST (on-demand)"
    echo ""
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  1. Table uses on-demand billing (pay per request)"
    echo "  2. No charges when not in use"
    echo "  3. Automatically scales with traffic"
    echo "  4. Cart service will use this table for persistent storage"
    echo ""
    echo -e "${BLUE}Cart Service Configuration:${NC}"
    echo "  The Cart service will be configured with:"
    echo -e "    ${CYAN}CARTS_DYNAMODB_TABLENAME=${DYNAMODB_TABLE_NAME}${NC}"
    echo -e "    ${CYAN}AWS_DEFAULT_REGION=${DYNAMODB_REGION}${NC}"
    echo ""
    echo -e "${BLUE}Useful Commands:${NC}"
    echo "  • Describe table:"
    echo -e "    ${CYAN}aws dynamodb describe-table --table-name ${DYNAMODB_TABLE_NAME} --region ${DYNAMODB_REGION}${NC}"
    echo "  • List tables:"
    echo -e "    ${CYAN}aws dynamodb list-tables --region ${DYNAMODB_REGION}${NC}"
    echo "  • Scan table (view items):"
    echo -e "    ${CYAN}aws dynamodb scan --table-name ${DYNAMODB_TABLE_NAME} --region ${DYNAMODB_REGION}${NC}"
    echo ""
    echo -e "${GREEN}Next Steps:${NC}"
    echo "  1. Deploy applications with Helm: ./06-helm-deploy.sh"
    echo "  2. Cart service will automatically connect to this DynamoDB table"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    create_dynamodb_table
    update_deployment_info
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       DynamoDB Setup Completed Successfully! 🎉       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
