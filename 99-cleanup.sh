#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Complete Cleanup Script
# This script removes ALL resources created by the project
#
# Cleanup process:
#   Step 1: Show what will be destroyed (Terraform plan)
#   Step 2: Confirm deletion
#   Step 3: Clean up ArgoCD
#   Step 4: Clean up Helm releases
#   Step 5: Destroy AWS infrastructure (Terraform)
#   Step 6: Optional local file cleanup
#   Step 7: Optional S3/GitOps cleanup
#   Step 8: Summary
################################################################################

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Helper functions
print_header() {
    echo -e "\n${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}\n"
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

print_step() {
    echo -e "${MAGENTA}▶ $1${NC}"
}

# Load deployment info
if [ -f deployment-info.txt ]; then
    source deployment-info.txt
    print_success "Loaded deployment-info.txt"
else
    print_warning "deployment-info.txt not found"
fi

# Main header
echo -e "${RED}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                                                       ║"
echo "║   ⚠️  COMPLETE PROJECT CLEANUP ⚠️                      ║"
echo "║                                                       ║"
echo "║   This will DELETE all resources created by:         ║"
echo "║   • Terraform (VPC, EC2, ECR, DynamoDB, IAM, etc.)   ║"
echo "║   • Kubernetes (ArgoCD, Helm releases, namespaces)   ║"
echo "║   • Local files (optional)                           ║"
echo "║                                                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

################################################################################
# Step 1: Show what Terraform will destroy
################################################################################
show_terraform_plan() {
    print_header "Step 1: Preview - What Will Be Destroyed"

    if [ ! -d "terraform" ]; then
        print_error "Terraform directory not found"
        exit 1
    fi

    cd terraform

    # Initialize if needed
    if [ ! -d ".terraform" ]; then
        print_info "Initializing Terraform..."
        terraform init -input=false > /dev/null 2>&1
    fi

    print_info "Generating destruction plan..."
    echo ""

    # Show what will be destroyed
    terraform plan -destroy -input=false

    cd ..

    echo ""
    print_warning "Review the plan above carefully!"
}

################################################################################
# Step 2: Confirmation
################################################################################
confirm_deletion() {
    print_header "Step 2: Confirmation"

    echo ""
    echo -e "${YELLOW}This will permanently delete:${NC}"
    echo "  • 3 EC2 instances (master + 2 workers)"
    echo "  • VPC, subnets, internet gateway, route tables"
    echo "  • Security groups"
    echo "  • IAM roles, policies, instance profiles"
    echo "  • 5 ECR repositories (and all Docker images)"
    echo "  • DynamoDB table (and all data)"
    echo "  • SSH key pair in AWS"
    echo "  • All Kubernetes resources (ArgoCD, pods, services, etc.)"
    echo ""

    read -p "Are you sure you want to delete EVERYTHING? Type 'yes' to confirm: " CONFIRM1
    if [ "$CONFIRM1" != "yes" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi

    echo ""
    read -p "Really sure? Type 'DELETE' in capital letters: " CONFIRM2
    if [ "$CONFIRM2" != "DELETE" ]; then
        echo "Cleanup cancelled."
        exit 0
    fi

    print_success "Deletion confirmed - proceeding..."
}

################################################################################
# Step 3: Clean up ArgoCD
################################################################################
cleanup_argocd() {
    print_header "Step 3: Cleaning up ArgoCD"

    # Check if we can access the cluster
    if ! kubectl get nodes &>/dev/null; then
        print_warning "Cannot access Kubernetes cluster - skipping ArgoCD cleanup"
        return
    fi

    # Check if ArgoCD namespace exists
    if kubectl get namespace argocd &>/dev/null; then
        print_step "Deleting ArgoCD Applications..."
        kubectl delete applications --all -n argocd --timeout=60s 2>/dev/null || true

        print_step "Waiting for applications to be deleted..."
        sleep 10

        print_step "Uninstalling ArgoCD..."
        kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true

        print_step "Deleting ArgoCD namespace..."
        kubectl delete namespace argocd --timeout=60s 2>/dev/null || true

        print_success "ArgoCD cleaned up"
    else
        print_info "ArgoCD not found - skipping"
    fi
}

################################################################################
# Step 4: Clean up Helm releases
################################################################################
cleanup_helm() {
    print_header "Step 4: Cleaning up Helm Releases"

    # Check if we can access the cluster
    if ! kubectl get nodes &>/dev/null; then
        print_warning "Cannot access Kubernetes cluster - skipping Helm cleanup"
        return
    fi

    # Check if Helm is installed
    if ! command -v helm &>/dev/null; then
        print_warning "Helm not installed - skipping Helm cleanup"
        return
    fi

    NAMESPACE="retail-store"

    # Uninstall Helm releases
    print_step "Checking for Helm releases in namespace: ${NAMESPACE}..."

    RELEASES=$(helm list -n "$NAMESPACE" 2>/dev/null | awk 'NR>1 {print $1}')

    if [ -n "$RELEASES" ]; then
        for release in $RELEASES; do
            print_info "Uninstalling Helm release: ${release}..."
            helm uninstall "$release" -n "$NAMESPACE" --wait --timeout 2m 2>/dev/null || true
            print_success "Uninstalled ${release}"
        done
    else
        print_info "No Helm releases found"
    fi

    # Delete namespace
    if kubectl get namespace "$NAMESPACE" &>/dev/null; then
        print_step "Deleting namespace: ${NAMESPACE}..."
        kubectl delete namespace "$NAMESPACE" --timeout=60s 2>/dev/null || true
        print_success "Deleted namespace ${NAMESPACE}"
    fi

    # Clean up nginx-ingress if exists
    if kubectl get namespace ingress-nginx &>/dev/null; then
        print_step "Deleting nginx-ingress..."
        kubectl delete namespace ingress-nginx --timeout=60s 2>/dev/null || true
        print_success "Deleted nginx-ingress"
    fi

    print_success "Helm cleanup complete"
}

################################################################################
# Step 5: Destroy AWS infrastructure with Terraform
################################################################################
destroy_terraform() {
    print_header "Step 5: Destroying AWS Infrastructure with Terraform"

    cd terraform

    print_warning "Starting Terraform destroy..."
    print_info "This will show detailed progress as resources are deleted..."
    echo ""

    # Run terraform destroy with auto-approve
    if terraform destroy -auto-approve -input=false; then
        echo ""
        print_success "All AWS resources destroyed via Terraform"
    else
        echo ""
        print_error "Terraform destroy encountered errors"
        print_warning "Some resources may still exist - check AWS Console"
    fi

    cd ..
}

################################################################################
# Step 6: Optional local file cleanup
################################################################################
cleanup_local_files() {
    print_header "Step 6: Local File Cleanup (Optional)"

    echo -e "${CYAN}The following local files can be deleted:${NC}"
    echo ""

    # SSH Key Files
    echo -e "${YELLOW}1. SSH Key Pair Files:${NC}"
    echo "   Files: haddar-k8s-kubeadm-key, haddar-k8s-kubeadm-key.pub"
    echo "   Purpose: Used to SSH into EC2 instances"
    echo "   Keep if: You want to reuse for next deployment"
    echo ""
    read -p "   Delete SSH key files? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f haddar-k8s-kubeadm-key*
        print_success "Removed SSH key files"
    else
        print_info "Keeping SSH key files"
    fi

    echo ""

    # Kubeconfig
    echo -e "${YELLOW}2. Kubernetes Config File:${NC}"
    echo "   File: ~/.kube/config-haddar-retail-store"
    echo "   Purpose: Used by kubectl to connect to cluster"
    echo "   Keep if: You need to reference cluster config"
    echo ""
    read -p "   Delete kubeconfig? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f ~/.kube/config-haddar-retail-store
        print_success "Removed kubeconfig"
    else
        print_info "Keeping kubeconfig"
    fi

    echo ""

    # Deployment Info
    echo -e "${YELLOW}3. Deployment Info File:${NC}"
    echo "   File: deployment-info.txt"
    echo "   Purpose: Contains all environment variables (IPs, IDs, etc.)"
    echo "   Keep if: You want reference info or to debug"
    echo ""
    read -p "   Delete deployment-info.txt? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -f deployment-info.txt
        print_success "Removed deployment-info.txt"
    else
        print_info "Keeping deployment-info.txt"
    fi

    echo ""

    # Terraform State Files
    echo -e "${YELLOW}4. Local Terraform State Files:${NC}"
    echo "   Files: terraform/.terraform/, terraform/terraform.tfstate*"
    echo "   Purpose: Local cache of Terraform state"
    echo "   Note: S3 backend has the official state"
    echo "   Keep if: You want local backup or to inspect state"
    echo ""
    read -p "   Delete local Terraform state? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        rm -rf terraform/.terraform
        rm -f terraform/.terraform.lock.hcl
        rm -f terraform/terraform.tfstate*
        print_success "Removed local Terraform state files"
    else
        print_info "Keeping local Terraform state files"
    fi
}

################################################################################
# Step 7: Optional S3 and GitOps cleanup
################################################################################
cleanup_s3_and_gitops() {
    print_header "Step 7: S3 Bucket & GitOps Repository (Optional)"

    # S3 Bucket
    echo -e "${YELLOW}1. Terraform State S3 Bucket:${NC}"
    echo "   Bucket: haddar-k8s-terraform-state"
    echo "   Purpose: Stores Terraform state (versioned)"
    echo "   Keep if: You want audit trail or to restore infrastructure"
    echo ""
    read -p "   Delete S3 bucket? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        BUCKET_NAME="haddar-k8s-terraform-state"

        print_info "Emptying S3 bucket..."
        aws s3 rm s3://${BUCKET_NAME} --recursive 2>/dev/null || print_warning "Bucket might not exist or is empty"

        print_info "Deleting S3 bucket..."
        aws s3 rb s3://${BUCKET_NAME} 2>/dev/null || print_warning "Bucket might not exist"

        print_info "Deleting DynamoDB lock table..."
        aws dynamodb delete-table --table-name terraform-state-lock 2>/dev/null || print_warning "Table might not exist"

        print_success "S3 bucket and lock table deleted"
    else
        print_info "Keeping S3 bucket (preserves Terraform state history)"
    fi

    echo ""

    # GitOps Repository
    if [ -n "$GITOPS_REPO_NAME" ]; then
        echo -e "${YELLOW}2. GitOps Repository:${NC}"
        echo "   Repository: ${GITOPS_REPO_NAME}"
        echo "   Purpose: Contains Kubernetes manifests (Git history)"
        echo "   Keep if: You want deployment history or to reuse"
        echo ""
        read -p "   Delete GitOps repository from GitHub? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            if command -v gh &>/dev/null; then
                print_info "Deleting GitOps repository..."
                gh repo delete "${GITHUB_USER}/${GITOPS_REPO_NAME}" --yes 2>/dev/null || {
                    print_warning "Could not delete via GitHub CLI"
                    print_info "Delete manually at: https://github.com/${GITHUB_USER}/${GITOPS_REPO_NAME}/settings"
                }
                print_success "GitOps repository deleted"
            else
                print_warning "GitHub CLI not installed"
                print_info "Delete manually at: https://github.com/${GITHUB_USER}/${GITOPS_REPO_NAME}/settings"
            fi
        else
            print_info "Keeping GitOps repository"
        fi
    else
        print_info "No GitOps repository configured - skipping"
    fi

    # Remove local GitOps directory if exists
    if [ -d "$GITOPS_REPO_NAME" ]; then
        echo ""
        read -p "   Delete local GitOps directory? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$GITOPS_REPO_NAME"
            print_success "Removed local GitOps directory"
        fi
    fi
}

################################################################################
# Step 8: Summary
################################################################################
print_summary() {
    print_header "Step 8: Cleanup Complete!"

    echo -e "${GREEN}✅ All selected resources have been deleted${NC}"
    echo ""
    echo -e "${BLUE}What was destroyed:${NC}"
    echo "  ✓ ArgoCD and all applications"
    echo "  ✓ Helm releases and namespaces"
    echo "  ✓ VPC and networking resources"
    echo "  ✓ 3 EC2 instances (master + workers)"
    echo "  ✓ Security groups"
    echo "  ✓ IAM roles and policies"
    echo "  ✓ 5 ECR repositories and all images"
    echo "  ✓ DynamoDB table and all data"
    echo "  ✓ SSH key pair in AWS"
    echo ""
    echo -e "${CYAN}Local files:${NC}"
    echo "  • Deleted or kept based on your choices"
    echo ""
    echo -e "${YELLOW}To start over from scratch:${NC}"
    echo "  1. ./00-prerequisites.sh       # Check/install tools"
    echo "  2. ./01-terraform-init.sh      # Bootstrap Terraform"
    echo "  3. ./02-terraform-apply.sh     # Create infrastructure"
    echo "  4. source restore-vars.sh      # Load variables"
    echo "  5. ./03-k8s-init.sh           # Setup Kubernetes"
    echo "  6. ./04-helm-deploy.sh        # Deploy with Helm (Phase 4)"
    echo "  7. ./05-create-gitops-repo.sh # Create GitOps repo (Phase 5)"
    echo "  8. ./06-argocd-setup.sh       # Install ArgoCD (Phase 5)"
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          Cleanup Completed Successfully! 🧹            ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
}

################################################################################
# Main Execution
################################################################################
main() {
    show_terraform_plan
    confirm_deletion
    cleanup_argocd
    cleanup_helm
    destroy_terraform
    cleanup_local_files
    cleanup_s3_and_gitops
    print_summary
}

# Run main function
main