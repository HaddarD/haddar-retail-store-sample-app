#!/bin/bash

################################################################################
# Prerequisites Check and Setup Script
# Verifies and installs all required tools for the project
#
# This script:
# 1. Checks for required tools (AWS CLI, kubectl, Terraform, Helm, jq)
# 2. Installs missing tools (where possible)
# 3. Verifies AWS credentials
# 4. Checks/creates SSH key pair
# 5. Provides setup instructions for manual steps
################################################################################

# Don't use set -e - we handle errors gracefully
# set -e

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

# Track what needs attention
MISSING_TOOLS=()
NEEDS_CONFIG=()
ALL_GOOD=true

# Main header
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Prerequisites Check - Haddar's K8s Project         ║"
echo "║   Verifying & Installing Required Tools              ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# ============================================================================
# 1. Check/Install jq (JSON processor)
# ============================================================================
check_jq() {
    print_header "Checking jq (JSON processor)"
    
    if command -v jq &> /dev/null; then
        JQ_VERSION=$(jq --version)
        print_success "jq installed: ${JQ_VERSION}"
    else
        print_warning "jq not found - installing..."
        
        if sudo apt-get update && sudo apt-get install -y jq; then
            print_success "jq installed successfully"
        else
            print_error "Failed to install jq"
            MISSING_TOOLS+=("jq")
            ALL_GOOD=false
        fi
    fi
}

# ============================================================================
# 2. Check AWS CLI
# ============================================================================
check_aws_cli() {
    print_header "Checking AWS CLI"
    
    if command -v aws &> /dev/null; then
        AWS_VERSION=$(aws --version)
        print_success "AWS CLI installed: ${AWS_VERSION}"
        
        # Check credentials
        print_info "Verifying AWS credentials..."
        if aws sts get-caller-identity &> /dev/null; then
            AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
            AWS_USER=$(aws sts get-caller-identity --query Arn --output text)
            print_success "AWS credentials configured"
            print_info "Account: ${AWS_ACCOUNT}"
            print_info "Identity: ${AWS_USER}"
        else
            print_error "AWS credentials not configured"
            NEEDS_CONFIG+=("aws-credentials")
            ALL_GOOD=false
            echo ""
            print_info "Configure with: aws configure"
            print_info "You need: AWS Access Key ID, Secret Access Key, Region"
        fi
    else
        print_error "AWS CLI not found"
        MISSING_TOOLS+=("aws-cli")
        ALL_GOOD=false
        echo ""
        print_info "Install from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
    fi
}

# ============================================================================
# 3. Check kubectl
# ============================================================================
check_kubectl() {
    print_header "Checking kubectl"
    
    if command -v kubectl &> /dev/null; then
        KUBECTL_VERSION=$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -n1)
        print_success "kubectl installed: ${KUBECTL_VERSION}"
    else
        print_error "kubectl not found"
        MISSING_TOOLS+=("kubectl")
        ALL_GOOD=false
        echo ""
        print_info "Install with:"
        echo "  curl -LO \"https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl\""
        echo "  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl"
    fi
}

# ============================================================================
# 4. Check/Install Terraform
# ============================================================================
check_terraform() {
    print_header "Checking Terraform"
    
    if command -v terraform &> /dev/null; then
        TERRAFORM_VERSION=$(terraform version | head -n1)
        print_success "Terraform installed: ${TERRAFORM_VERSION}"
    else
        print_warning "Terraform not found - attempting to install..."
        
        # Try to install Terraform
        if install_terraform; then
            print_success "Terraform installed successfully"
        else
            print_error "Failed to install Terraform"
            MISSING_TOOLS+=("terraform")
            ALL_GOOD=false
            echo ""
            print_info "Manual install: https://www.terraform.io/downloads"
        fi
    fi
}

install_terraform() {
    # Check if running on supported OS
    if [[ ! -f /etc/os-release ]]; then
        return 1
    fi
    
    print_info "Installing Terraform..."
    
    # Add HashiCorp GPG key
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null
    
    # Add HashiCorp repository
    DISTRO=$(lsb_release -cs 2>/dev/null || echo "jammy")
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${DISTRO} main" | sudo tee /etc/apt/sources.list.d/hashicorp.list > /dev/null
    
    # Install Terraform
    if sudo apt-get update && sudo apt-get install -y terraform; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# 5. Check/Install Helm
# ============================================================================
check_helm() {
    print_header "Checking Helm"
    
    if command -v helm &> /dev/null; then
        HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
        print_success "Helm installed: ${HELM_VERSION}"
    else
        print_warning "Helm not found - installing..."
        
        if install_helm; then
            print_success "Helm installed successfully"
            
            # Add common repositories
            print_info "Adding Helm repositories..."
            helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
            helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
            helm repo update > /dev/null 2>&1
            print_success "Helm repositories configured"
        else
            print_error "Failed to install Helm"
            MISSING_TOOLS+=("helm")
            ALL_GOOD=false
        fi
    fi
}

install_helm() {
    print_info "Downloading Helm installation script..."
    
    # Download and run official Helm installer
    if curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# 6. Check Git
# ============================================================================
check_git() {
    print_header "Checking Git"
    
    if command -v git &> /dev/null; then
        GIT_VERSION=$(git --version)
        print_success "Git installed: ${GIT_VERSION}"
        
        # Check git config
        if git config --get user.name &> /dev/null && git config --get user.email &> /dev/null; then
            GIT_NAME=$(git config --get user.name)
            GIT_EMAIL=$(git config --get user.email)
            print_success "Git configured: ${GIT_NAME} <${GIT_EMAIL}>"
        else
            print_warning "Git not fully configured"
            NEEDS_CONFIG+=("git")
            echo ""
            print_info "Configure with:"
            echo "  git config --global user.name \"Your Name\""
            echo "  git config --global user.email \"your.email@example.com\""
        fi
    else
        print_error "Git not found (should be pre-installed on Ubuntu)"
        MISSING_TOOLS+=("git")
        ALL_GOOD=false
    fi
}

# ============================================================================
# 7. Check SSH Key Pair
# ============================================================================
check_ssh_key() {
    print_header "Checking SSH Key Pair"
    
    KEY_NAME="haddar-k8s-kubeadm-key"
    
    if [ -f "${KEY_NAME}" ] && [ -f "${KEY_NAME}.pub" ]; then
        print_success "SSH key pair found: ${KEY_NAME}"
        
        # Check permissions
        PERMS=$(stat -c %a "${KEY_NAME}" 2>/dev/null || stat -f %A "${KEY_NAME}" 2>/dev/null)
        if [ "$PERMS" != "600" ] && [ "$PERMS" != "400" ]; then
            print_warning "Fixing SSH key permissions..."
            chmod 600 "${KEY_NAME}"
            print_success "Permissions fixed"
        fi
    else
        print_warning "SSH key pair not found"
        echo ""
        read -p "Generate SSH key pair now? (y/n): " -n 1 -r
        echo ""
        
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Generating SSH key pair..."
            ssh-keygen -t rsa -b 4096 -f "${KEY_NAME}" -N "" -C "haddar-k8s-kubeadm"
            chmod 600 "${KEY_NAME}"
            print_success "SSH key pair generated: ${KEY_NAME}"
        else
            print_warning "SSH key pair required for EC2 instances"
            NEEDS_CONFIG+=("ssh-key")
            ALL_GOOD=false
            echo ""
            print_info "Generate manually with:"
            echo "  ssh-keygen -t rsa -b 4096 -f ${KEY_NAME} -N \"\""
        fi
    fi
}

# ============================================================================
# 8. Check Disk Space
# ============================================================================
check_disk_space() {
    print_header "Checking Disk Space"
    
    AVAILABLE=$(df -BG . | tail -1 | awk '{print $4}' | sed 's/G//')
    
    if [ "$AVAILABLE" -gt 10 ]; then
        print_success "Sufficient disk space: ${AVAILABLE}GB available"
    else
        print_warning "Low disk space: only ${AVAILABLE}GB available"
        print_info "Recommended: At least 10GB free"
    fi
}

# ============================================================================
# Main Execution
# ============================================================================
main() {
    check_jq
    check_aws_cli
    check_kubectl
    check_terraform
    check_helm
    check_git
    check_ssh_key
    check_disk_space
    
    # Print summary
    print_header "Prerequisites Check Complete"
    
    if [ "$ALL_GOOD" = true ]; then
        echo -e "${GREEN}"
        echo "╔═══════════════════════════════════════════════════════╗"
        echo "║         ✅ ALL PREREQUISITES MET! ✅                  ║"
        echo "╚═══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        echo -e "${BLUE}You're ready to proceed!${NC}"
        echo ""
        echo -e "${CYAN}Next Steps:${NC}"
        echo "  1. Bootstrap Terraform:        ./01-terraform-init.sh"
        echo "  2. Create infrastructure:      ./02-terraform-apply.sh"
        echo "  3. Setup Kubernetes:           ./03-k8s-init.sh"
        echo "  4. Deploy with Helm:           ./04-helm-deploy.sh"
        echo "  5. Setup GitOps:               ./05-create-gitops-repo.sh"
        echo "  6. Install ArgoCD:             ./06-argocd-setup.sh"
        echo ""
    else
        echo -e "${YELLOW}"
        echo "╔═══════════════════════════════════════════════════════╗"
        echo "║      ⚠️  SOME PREREQUISITES NEED ATTENTION ⚠️         ║"
        echo "╚═══════════════════════════════════════════════════════╝"
        echo -e "${NC}"
        echo ""
        
        if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
            echo -e "${RED}Missing Tools:${NC}"
            for tool in "${MISSING_TOOLS[@]}"; do
                echo "  • $tool"
            done
            echo ""
        fi
        
        if [ ${#NEEDS_CONFIG[@]} -gt 0 ]; then
            echo -e "${YELLOW}Needs Configuration:${NC}"
            for config in "${NEEDS_CONFIG[@]}"; do
                echo "  • $config"
            done
            echo ""
        fi
        
        echo -e "${CYAN}Please address the items above, then run this script again.${NC}"
        echo ""
        exit 1
    fi
}

# Run main function
main

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Prerequisites Check Completed Successfully! 🎉    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
