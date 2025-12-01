#!/bin/bash

################################################################################
# ArgoCD Setup Script - Phase 5
# Install ArgoCD and configure GitOps deployment
#
# This script:
# 1. Uninstalls existing Helm releases (so ArgoCD can take over)
# 2. Installs ArgoCD on the Kubernetes cluster
# 3. Exposes ArgoCD UI via NodePort
# 4. Applies ArgoCD Application manifests from GitOps repo
# 5. Waits for applications to sync
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
ARGOCD_NAMESPACE="argocd"
ARGOCD_NODEPORT="30090"
NAMESPACE="retail-store"

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
echo "║   ArgoCD Setup - Phase 5 GitOps Deployment           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        exit 1
    fi
    print_success "kubectl found"
    
    # Check cluster connection
    if ! kubectl get nodes &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi
    print_success "Connected to cluster"
    
    # Check GitOps variables
    if [ -z "$GITOPS_REPO_URL" ]; then
        print_error "GitOps repository URL not found"
        print_info "Please run ./05-create-gitops-repo.sh first"
        exit 1
    fi
    print_success "GitOps repo configured: ${GITOPS_REPO_URL}"
}

# Uninstall existing Helm releases
uninstall_helm_releases() {
    print_header "Uninstalling Existing Helm Releases"
    
    print_info "ArgoCD will take over application management"
    echo ""
    
    # Uninstall retail-store
    if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "retail-store"; then
        print_info "Uninstalling retail-store Helm release..."
        helm uninstall retail-store -n ${NAMESPACE} --wait --timeout 3m || print_warning "Issue uninstalling"
        print_success "retail-store uninstalled"
    else
        print_info "retail-store not found (already uninstalled)"
    fi
    
    # Uninstall dependencies
    for DEP in postgresql redis rabbitmq; do
        if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^${DEP}"; then
            print_info "Uninstalling ${DEP}..."
            helm uninstall ${DEP} -n ${NAMESPACE} --wait --timeout 3m || print_warning "Issue uninstalling"
            print_success "${DEP} uninstalled"
        fi
    done
    
    # Keep nginx-ingress
    print_info "Keeping nginx-ingress (required for external access)"
    
    print_success "Helm releases uninstalled"
}

# Install ArgoCD
install_argocd() {
    print_header "Installing ArgoCD"
    
    # Check if already installed
    if kubectl get namespace $ARGOCD_NAMESPACE &> /dev/null; then
        print_warning "ArgoCD namespace already exists"
        read -p "Reinstall ArgoCD? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_info "Skipping ArgoCD installation"
            return
        fi
        kubectl delete namespace $ARGOCD_NAMESPACE --timeout=60s || true
        sleep 5
    fi
    
    # Create namespace
    kubectl create namespace $ARGOCD_NAMESPACE
    
    # Install ArgoCD
    print_info "Installing ArgoCD (this may take 2-3 minutes)..."
    kubectl apply -n $ARGOCD_NAMESPACE -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    
    # Wait for ArgoCD to be ready
    print_info "Waiting for ArgoCD pods to be ready..."
    kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server -n $ARGOCD_NAMESPACE
    
    print_success "ArgoCD installed"
}

# Expose ArgoCD UI via NodePort
expose_argocd_ui() {
    print_header "Exposing ArgoCD UI"
    
    print_info "Configuring NodePort service..."
    kubectl patch svc argocd-server -n $ARGOCD_NAMESPACE -p \
        "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":443,\"nodePort\":${ARGOCD_NODEPORT},\"name\":\"https\"}]}}"
    
    # Disable TLS (for easier access)
    kubectl patch configmap argocd-cmd-params-cm -n $ARGOCD_NAMESPACE \
        --type merge -p '{"data":{"server.insecure":"true"}}'
    
    # Restart server to apply changes
    kubectl rollout restart deployment argocd-server -n $ARGOCD_NAMESPACE
    kubectl rollout status deployment argocd-server -n $ARGOCD_NAMESPACE
    
    print_success "ArgoCD UI exposed on port ${ARGOCD_NODEPORT}"
}

# Get ArgoCD admin password
get_argocd_password() {
    print_header "Retrieving ArgoCD Admin Password"
    
    ARGOCD_ADMIN_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
        -n $ARGOCD_NAMESPACE \
        -o jsonpath="{.data.password}" | base64 -d)
    
    # Save to deployment-info.txt
    if grep -q "ARGOCD_ADMIN_PASSWORD" deployment-info.txt; then
        sed -i "s|^export ARGOCD_ADMIN_PASSWORD=.*|export ARGOCD_ADMIN_PASSWORD=\"${ARGOCD_ADMIN_PASSWORD}\"|" deployment-info.txt
    else
        echo "" >> deployment-info.txt
        echo "# ArgoCD Configuration" >> deployment-info.txt
        echo "export ARGOCD_ADMIN_PASSWORD=\"${ARGOCD_ADMIN_PASSWORD}\"" >> deployment-info.txt
    fi
    
    print_success "ArgoCD password saved to deployment-info.txt"
}

# Clone GitOps repo and apply applications
apply_argocd_applications() {
    print_header "Applying ArgoCD Applications"
    
    # Clone GitOps repo
    TEMP_DIR=$(mktemp -d)
    print_info "Cloning GitOps repository..."
    git clone "$GITOPS_REPO_URL" "$TEMP_DIR" || {
        print_error "Failed to clone GitOps repository"
        exit 1
    }
    
    # Apply ArgoCD applications
    print_info "Applying ArgoCD Application manifests..."
    kubectl apply -f "$TEMP_DIR/argocd/applications/" -n $ARGOCD_NAMESPACE
    
    # Cleanup
    rm -rf "$TEMP_DIR"
    
    print_success "ArgoCD applications configured"
}

# Wait for applications to sync
wait_for_sync() {
    print_header "Waiting for Applications to Sync"
    
    print_info "ArgoCD is syncing applications (this may take 5-10 minutes)..."
    echo ""
    
    sleep 30
    
    # Check application status
    kubectl get applications -n $ARGOCD_NAMESPACE
    
    print_success "Applications are syncing"
}

# Verify deployment
verify_deployment() {
    print_header "Verifying Deployment"
    
    echo ""
    print_info "Checking pods in retail-store namespace..."
    kubectl get pods -n $NAMESPACE
    
    echo ""
    print_info "Checking ArgoCD applications..."
    kubectl get applications -n $ARGOCD_NAMESPACE
}

# Print summary
print_summary() {
    print_header "ArgoCD Setup Complete!"
    
    echo -e "${GREEN}✅ ArgoCD is now managing your applications!${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Access Information                                    ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}🛒 Retail Store App:${NC}"
    echo -e "   ${GREEN}http://${MASTER_PUBLIC_IP}:30080${NC}"
    echo ""
    echo -e "${CYAN}🚀 ArgoCD Dashboard:${NC}"
    echo -e "   ${GREEN}https://${MASTER_PUBLIC_IP}:${ARGOCD_NODEPORT}${NC}"
    echo -e "   Username: ${YELLOW}admin${NC}"
    echo -e "   Password: ${YELLOW}${ARGOCD_ADMIN_PASSWORD}${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  • ArgoCD is now managing all deployments"
    echo "  • Helm releases have been uninstalled"
    echo "  • Changes to GitOps repo will auto-deploy"
    echo "  • Images pull from ECR using IAM role (no secrets!)"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  kubectl get applications -n argocd"
    echo "  kubectl get pods -n retail-store"
    echo "  ./Display-App-URLs.sh"
}

# Main execution
main() {
    check_prerequisites
    uninstall_helm_releases
    install_argocd
    expose_argocd_ui
    get_argocd_password
    apply_argocd_applications
    wait_for_sync
    verify_deployment
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      ArgoCD Setup Completed Successfully! 🎉         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
