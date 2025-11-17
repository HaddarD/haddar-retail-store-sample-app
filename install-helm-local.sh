#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Install Helm on Local Machine
# This script installs Helm 3 on your local machine (NOT on EC2 instances)
# 
# ONE-TIME SETUP - Run this script once on your local machine
#
# Usage: ./install-helm-local.sh
################################################################################

set -e  # Exit on any error

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

# Main header
echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Install Helm on Local Machine - ONE TIME SETUP     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check if Helm is already installed
print_header "Checking if Helm is Already Installed"

if command -v helm &> /dev/null; then
    CURRENT_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null || echo "unknown")
    print_warning "Helm is already installed: ${CURRENT_VERSION}"
    echo ""
    echo -n "Do you want to reinstall/upgrade Helm? (y/n): "
    read -r response
    
    if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
        print_info "Keeping existing Helm installation"
        echo ""
        print_success "Helm is ready to use!"
        echo ""
        echo "Verify with: helm version"
        exit 0
    fi
    
    print_info "Proceeding with Helm reinstallation..."
fi

# Detect OS
print_header "Detecting Operating System"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case $ARCH in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        print_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

print_success "Detected OS: ${OS}"
print_success "Detected Architecture: ${ARCH}"

# Install Helm
print_header "Installing Helm"

print_info "Downloading Helm installation script..."

# Download and run the official Helm installer
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify installation
print_header "Verifying Helm Installation"

if command -v helm &> /dev/null; then
    HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
    print_success "Helm installed successfully!"
    print_info "Version: ${HELM_VERSION}"
else
    print_error "Helm installation failed"
    exit 1
fi

# Add Helm repositories
print_header "Adding Common Helm Repositories"

print_info "Adding Bitnami repository..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || print_warning "Bitnami repo already exists"

print_info "Adding NGINX Ingress repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || print_warning "NGINX Ingress repo already exists"

print_info "Updating Helm repositories..."
helm repo update

print_success "Helm repositories configured"

# Summary
print_header "Installation Complete!"

echo -e "${GREEN}✓ Helm 3 is now installed on your local machine${NC}"
echo ""
echo -e "${BLUE}Useful Helm Commands:${NC}"
echo "  helm version              # Check Helm version"
echo "  helm repo list            # List configured repositories"
echo "  helm repo update          # Update repository information"
echo "  helm list                 # List deployed releases"
echo "  helm install <n> <chart>   # Install a chart"
echo "  helm uninstall <n>     # Uninstall a release"
echo ""
echo -e "${YELLOW}Important Notes:${NC}"
echo "  • Helm is a CLIENT tool that runs on YOUR local machine"
echo "  • It communicates with your Kubernetes cluster via kubectl"
echo "  • Make sure kubectl is configured before using Helm"
echo ""
echo -e "${GREEN}Next Steps:${NC}"
echo "  1. Ensure kubectl is configured: kubectl get nodes"
echo "  2. Proceed with DynamoDB setup: ./05-dynamodb-setup.sh"
echo "  3. Deploy applications: ./06-helm-deploy.sh"
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║       Helm Installation Completed Successfully!      ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
