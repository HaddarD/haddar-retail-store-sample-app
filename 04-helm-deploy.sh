#!/bin/bash

################################################################################
# Helm Deployment Script - Phase 4 Demonstration
# Deploy the retail store application using Helm
#
# This script:
# 1. Creates the retail-store namespace
# 2. Deploys PostgreSQL, Redis, RabbitMQ using Bitnami charts
# 3. Deploys all 5 microservices using custom Helm chart
# 4. Installs nginx-ingress controller
# 5. Verifies all pods are running
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
NAMESPACE="retail-store"
HELM_RELEASE="retail-store"
DEPENDENCIES_RELEASE="dependencies"

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
echo "║   Helm Deployment - Phase 4 Demonstration            ║"
echo "║   Deploy Retail Store Application with Helm          ║"
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
    
    # Check Helm
    if ! command -v helm &> /dev/null; then
        print_error "Helm not found. Run ./00-prerequisites.sh first."
        exit 1
    fi
    HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
    print_success "Helm found: ${HELM_VERSION}"
    
    # Check cluster connection
    if ! kubectl get nodes &> /dev/null; then
        print_error "Cannot connect to Kubernetes cluster"
        print_info "Make sure: export KUBECONFIG=~/.kube/config-haddar-retail-store"
        exit 1
    fi
    print_success "Connected to Kubernetes cluster"
    
    # Show cluster info
    NODES=$(kubectl get nodes --no-headers | wc -l)
    print_info "Cluster has ${NODES} nodes"
}

# Create namespace
create_namespace() {
    print_header "Creating Namespace"
    
    if kubectl get namespace $NAMESPACE &> /dev/null; then
        print_warning "Namespace '${NAMESPACE}' already exists"
    else
        kubectl create namespace $NAMESPACE
        print_success "Namespace '${NAMESPACE}' created"
    fi
}

# Deploy dependencies (PostgreSQL, Redis, RabbitMQ)
deploy_dependencies() {
    print_header "Deploying Dependencies (PostgreSQL, Redis, RabbitMQ)"
    
    # Add Bitnami repo if not exists
    print_info "Adding Bitnami Helm repository..."
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || print_warning "Bitnami repo already exists"
    helm repo update
    
    print_success "Helm repositories updated"
    
    # Deploy PostgreSQL
    print_info "Deploying PostgreSQL..."
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace $NAMESPACE \
        --set auth.username=retail \
        --set auth.password=retail123 \
        --set auth.database=retail \
        --set primary.persistence.enabled=false \
        --set readReplicas.persistence.enabled=false \
        --wait --timeout=10m
    
    print_success "PostgreSQL deployed"
    
    # Deploy Redis
    print_info "Deploying Redis..."
    helm upgrade --install redis bitnami/redis \
        --namespace $NAMESPACE \
        --set auth.enabled=false \
        --set master.persistence.enabled=false \
        --set replica.persistence.enabled=false \
        --wait --timeout=10m
    
    print_success "Redis deployed"
    
    # Deploy RabbitMQ
    print_info "Deploying RabbitMQ (this may take a few minutes)..."
    helm upgrade --install rabbitmq bitnami/rabbitmq \
        --namespace $NAMESPACE \
        --set auth.username=admin \
        --set auth.password=admin123 \
        --set persistence.enabled=false \
        --set replicaCount=1 \
        --set resources.requests.memory=512Mi \
        --set resources.requests.cpu=250m \
        --set livenessProbe.timeoutSeconds=10 \
        --set readinessProbe.timeoutSeconds=10 \
        --wait --timeout=15m
    
    print_success "RabbitMQ deployed"
}

# Update Helm chart values with current ECR URLs
update_helm_values() {
    print_header "Updating Helm Chart Values"
    
    print_info "Updating values.yaml with current ECR repository URLs..."
    
    # Backup original
    cp helm-chart/values.yaml helm-chart/values.yaml.bak 2>/dev/null || true
    
    # Update ECR URLs
    sed -i "s|repository:.*retail-store-ui|repository: ${ECR_UI_REPO}|" helm-chart/values.yaml
    sed -i "s|repository:.*retail-store-catalog|repository: ${ECR_CATALOG_REPO}|" helm-chart/values.yaml
    sed -i "s|repository:.*retail-store-cart|repository: ${ECR_CART_REPO}|" helm-chart/values.yaml
    sed -i "s|repository:.*retail-store-orders|repository: ${ECR_ORDERS_REPO}|" helm-chart/values.yaml
    sed -i "s|repository:.*retail-store-checkout|repository: ${ECR_CHECKOUT_REPO}|" helm-chart/values.yaml
    
    print_success "Helm values updated with ECR repository URLs"
}

# Deploy application
deploy_application() {
    print_header "Deploying Retail Store Application"
    
    print_info "Deploying microservices with Helm..."
    
    helm upgrade --install $HELM_RELEASE ./helm-chart \
        --namespace $NAMESPACE \
        --set global.dynamodbTableName=$DYNAMODB_TABLE_NAME \
        --set global.region=$REGION \
        --wait --timeout=10m
    
    print_success "Application deployed with Helm"
}

# Install nginx-ingress
install_ingress() {
    print_header "Installing nginx-ingress Controller"
    
    print_info "Adding nginx-ingress repository..."
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update
    
    print_info "Deploying nginx-ingress..."
    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --namespace $NAMESPACE \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30080 \
        --set controller.service.nodePorts.https=30443 \
        --wait --timeout=5m
    
    print_success "nginx-ingress controller installed"
}

# Verify deployment
verify_deployment() {
    print_header "Verifying Deployment"
    
    print_info "Waiting for all pods to be ready (this may take 3-5 minutes)..."
    
    # Wait for pods
    kubectl wait --for=condition=ready pod \
        --all \
        --namespace=$NAMESPACE \
        --timeout=600s 2>/dev/null || print_warning "Some pods may still be starting..."
    
    echo ""
    print_info "Checking pod status..."
    kubectl get pods -n $NAMESPACE
    
    echo ""
    print_info "Checking services..."
    kubectl get svc -n $NAMESPACE
}

# Print access information
print_access_info() {
    print_header "Application Access Information"
    
    echo -e "${GREEN}✅ Application deployed successfully with Helm!${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Access Your Application                               ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}🛒 Retail Store Application:${NC}"
    echo -e "   ${GREEN}http://${MASTER_PUBLIC_IP}:30080${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}📋 Deployment Details:${NC}"
    echo "  Namespace:        ${NAMESPACE}"
    echo "  Helm Release:     ${HELM_RELEASE}"
    echo "  Ingress:          nginx (NodePort 30080)"
    echo ""
    echo -e "${CYAN}Useful Commands:${NC}"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  kubectl get svc -n ${NAMESPACE}"
    echo "  kubectl logs -n ${NAMESPACE} -l app=ui --tail=50"
    echo "  helm list -n ${NAMESPACE}"
    echo ""
    echo -e "${YELLOW}⚠️  Important Notes:${NC}"
    echo "  • This is Phase 4 - Helm deployment demonstration"
    echo "  • Images pulled from ECR using IAM role (no secrets!)"
    echo "  • Application is fully managed by Helm"
    echo "  • Next: Phase 5 - Transition to ArgoCD (GitOps)"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Test the application in your browser"
    echo "  2. Proceed to Phase 5: ./05-create-gitops-repo.sh"
    echo "  3. Install ArgoCD:      ./06-argocd-setup.sh"
}

# Main execution
main() {
    check_prerequisites
    create_namespace
    deploy_dependencies
    update_helm_values
    deploy_application
    install_ingress
    verify_deployment
    print_access_info
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Helm Deployment Completed Successfully! 🎉       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
