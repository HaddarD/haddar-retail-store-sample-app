#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Helm Deployment Script
# Phase 4: Deploy all microservices and dependencies using Helm
#
# This script:
# 1. Verifies cluster connectivity
# 2. Installs dependencies (PostgreSQL, Redis, RabbitMQ)
# 3. Deploys the retail-store application via Helm
# 4. Installs nginx-ingress for external access
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
HELM_CHART_DIR="helm-chart"
KUBECONFIG_PATH="$HOME/.kube/config-haddar-retail-store"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

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
echo "║   Kubernetes kubeadm Cluster - Helm Deployment       ║"
echo "║   Phase 4: Application & Dependencies Deployment     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"

    # Check Helm
    if ! command -v helm &> /dev/null; then
        print_error "Helm not found. Please run: ./00-prerequisites.sh"
        exit 1
    fi
    HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
    print_success "Helm installed: ${HELM_VERSION}"

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        exit 1
    fi
    print_success "kubectl installed"

    # Check SSH key
    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key not found: $KEY_FILE"
        exit 1
    fi
    print_success "SSH key found"

    # Check helm-chart directory
    if [ ! -d "$HELM_CHART_DIR" ]; then
        print_error "Helm chart directory not found: $HELM_CHART_DIR"
        print_info "Make sure you're running from the project root directory"
        exit 1
    fi
    print_success "Helm chart directory found"
}

# Setup kubectl configuration
setup_kubectl() {
    print_header "Configuring kubectl"

    mkdir -p ~/.kube

    # Check if kubeconfig already exists and is working
    if [ -f "$KUBECONFIG_PATH" ]; then
        export KUBECONFIG="$KUBECONFIG_PATH"
        if kubectl get nodes &>/dev/null; then
            print_success "Using existing kubeconfig: $KUBECONFIG_PATH"
            return 0
        else
            print_warning "Existing kubeconfig not working, refreshing..."
        fi
    fi

    # Copy fresh kubeconfig from master
    print_info "Copying kubeconfig from master node..."
    scp -o StrictHostKeyChecking=no -i "$KEY_FILE" \
        ubuntu@$MASTER_PUBLIC_IP:~/.kube/config \
        "$KUBECONFIG_PATH" 2>/dev/null

    if [ ! -f "$KUBECONFIG_PATH" ]; then
        print_error "Failed to copy kubeconfig from master"
        print_info "Make sure the cluster is initialized (./03-k8s-init.sh)"
        exit 1
    fi

    # Update server address to use public IP
    sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|g" "$KUBECONFIG_PATH"

    # Add TLS skip if not already present (needed because cert is for private IP)
    if ! grep -q "insecure-skip-tls-verify: true" "$KUBECONFIG_PATH"; then
        sed -i '/certificate-authority-data:/d' "$KUBECONFIG_PATH"
        sed -i '/server: https/a\    insecure-skip-tls-verify: true' "$KUBECONFIG_PATH"
        print_info "Added TLS skip to kubeconfig"
    fi

    export KUBECONFIG="$KUBECONFIG_PATH"
    print_success "KUBECONFIG set to: $KUBECONFIG_PATH"

    # Verify connection
    if kubectl get nodes &>/dev/null; then
        print_success "kubectl connected to cluster"
    else
        print_error "Cannot connect to cluster"
        exit 1
    fi
}

# Verify cluster is ready
verify_cluster() {
    print_header "Verifying Cluster Status"

    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [ "$NODE_COUNT" -lt 3 ]; then
        print_error "Cluster has only $NODE_COUNT node(s). Expected 3"
        print_info "Make sure 03-k8s-init.sh completed successfully"
        exit 1
    fi
    print_success "Cluster has $NODE_COUNT nodes"

    # Check if all nodes are Ready
    READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
    if [ "$READY_COUNT" -lt 3 ]; then
        print_warning "Only $READY_COUNT nodes are Ready, waiting..."
        sleep 30
        READY_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
    fi
    print_success "$READY_COUNT nodes are Ready"

    kubectl get nodes
}

# Create namespace with proper labels
create_namespace() {
    print_header "Creating Namespace"

    if kubectl get namespace $NAMESPACE &> /dev/null; then
        print_warning "Namespace '${NAMESPACE}' already exists"
        # Add Helm labels to existing namespace for proper management
        kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null || true
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=retail-store --overwrite 2>/dev/null || true
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=retail-store --overwrite 2>/dev/null || true
        print_info "Helm labels added to existing namespace"
    else
        kubectl create namespace $NAMESPACE
        kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=retail-store
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=retail-store
        print_success "Namespace '${NAMESPACE}' created with Helm labels"
    fi
}

# Add Helm repositories
add_helm_repos() {
    print_header "Adding Helm Repositories"

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || print_info "Bitnami repo already exists"
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || print_info "Ingress-nginx repo already exists"
    helm repo update

    print_success "Helm repositories configured"
}

# Install PostgreSQL
install_postgresql() {
    print_header "Installing PostgreSQL (for Catalog & Orders)"

    # Check if already installed
    if helm list -n $NAMESPACE 2>/dev/null | grep -q "^postgresql"; then
        print_warning "PostgreSQL already installed, upgrading..."
    fi

    print_info "Deploying PostgreSQL..."
    helm upgrade --install postgresql bitnami/postgresql \
        --namespace $NAMESPACE \
        --set auth.postgresPassword=postgres \
        --set auth.database=catalog \
        --set primary.persistence.enabled=false \
        --set volumePermissions.enabled=true \
        --wait --timeout=10m

    print_success "PostgreSQL deployed"
}

# Install Redis
install_redis() {
    print_header "Installing Redis (for Cart)"

    if helm list -n $NAMESPACE 2>/dev/null | grep -q "^redis"; then
        print_warning "Redis already installed, upgrading..."
    fi

    print_info "Deploying Redis..."
    helm upgrade --install redis bitnami/redis \
        --namespace $NAMESPACE \
        --set auth.enabled=false \
        --set master.persistence.enabled=false \
        --set replica.replicaCount=0 \
        --set replica.persistence.enabled=false \
        --wait --timeout=10m

    print_success "Redis deployed"
}

# Install RabbitMQ (using kubectl for simpler setup)
install_rabbitmq() {
    print_header "Installing RabbitMQ (for Checkout)"

    # Clean up existing if present
    kubectl delete deployment rabbitmq -n $NAMESPACE 2>/dev/null || true
    kubectl delete service rabbitmq -n $NAMESPACE 2>/dev/null || true
    sleep 3

    print_info "Deploying RabbitMQ..."
    kubectl apply -n $NAMESPACE -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq
  labels:
    app: rabbitmq
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rabbitmq
  template:
    metadata:
      labels:
        app: rabbitmq
    spec:
      containers:
      - name: rabbitmq
        image: rabbitmq:3.13-management
        ports:
        - containerPort: 5672
          name: amqp
        - containerPort: 15672
          name: management
        env:
        - name: RABBITMQ_DEFAULT_USER
          value: "guest"
        - name: RABBITMQ_DEFAULT_PASS
          value: "guest"
        resources:
          requests:
            memory: "256Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
spec:
  selector:
    app: rabbitmq
  ports:
  - port: 5672
    targetPort: 5672
    name: amqp
  - port: 15672
    targetPort: 15672
    name: management
EOF

    print_info "Waiting for RabbitMQ to be ready..."
    kubectl wait --for=condition=available --timeout=300s deployment/rabbitmq -n $NAMESPACE

    print_success "RabbitMQ deployed"
}

# Deploy retail store application
deploy_application() {
    print_header "Deploying Retail Store Application"

    # Check if already installed
    if helm list -n $NAMESPACE 2>/dev/null | grep -q "^retail-store"; then
        print_warning "retail-store already installed, upgrading..."
    fi

    print_info "Deploying microservices from $HELM_CHART_DIR..."
    helm upgrade --install retail-store ./$HELM_CHART_DIR \
        --namespace $NAMESPACE \
        --set global.ecr.registry=$ECR_REGISTRY \
        --set global.dynamodb.tableName=$DYNAMODB_TABLE_NAME \
        --set global.dynamodb.region=$REGION \
        --wait --timeout=10m

    print_success "Retail store application deployed"
}

# Install nginx-ingress controller
install_ingress() {
    print_header "Installing nginx-ingress Controller"

    # Create ingress-nginx namespace if not exists
    kubectl create namespace ingress-nginx 2>/dev/null || true

    # Check if already installed
    if helm list -n ingress-nginx 2>/dev/null | grep -q "^nginx-ingress"; then
        print_warning "nginx-ingress already installed, upgrading..."
    fi

    print_info "Deploying nginx-ingress..."
    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30080 \
        --set controller.service.nodePorts.https=30443 \
        --wait --timeout=5m

    print_success "nginx-ingress installed on NodePort 30080/30443"
}

# Verify deployment
verify_deployment() {
    print_header "Verifying Deployment"

    echo -e "${CYAN}=== Pods in ${NAMESPACE} ===${NC}"
    kubectl get pods -n $NAMESPACE

    echo ""
    print_info "Waiting for all pods to be ready (timeout 5 minutes)..."
    if kubectl wait --for=condition=ready pod --all -n $NAMESPACE --timeout=300s 2>/dev/null; then
        print_success "All pods are ready!"
    else
        print_warning "Some pods may still be starting"
        echo ""
        kubectl get pods -n $NAMESPACE
    fi

    echo ""
    echo -e "${CYAN}=== Services in ${NAMESPACE} ===${NC}"
    kubectl get svc -n $NAMESPACE

    echo ""
    echo -e "${CYAN}=== Helm Releases ===${NC}"
    helm list -n $NAMESPACE
}

# Print summary
print_summary() {
    print_header "Deployment Complete!"

    echo -e "${GREEN}✅ Application deployed successfully with Helm!${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Access Information                                    ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${CYAN}🛒 Retail Store Application:${NC}"
    echo -e "   ${GREEN}http://${MASTER_PUBLIC_IP}:30080${NC}"
    echo ""
    echo -e "${BLUE}════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  kubectl get svc -n ${NAMESPACE}"
    echo "  kubectl logs -n ${NAMESPACE} -l app=ui --tail=50"
    echo "  helm list -n ${NAMESPACE}"
    echo ""
    echo -e "${CYAN}Troubleshooting:${NC}"
    echo "  kubectl describe pod -n ${NAMESPACE} <pod-name>"
    echo "  kubectl logs -n ${NAMESPACE} <pod-name>"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  Option A: You're done! Access the app at the URL above"
    echo "  Option B: Setup GitOps with ArgoCD:"
    echo "            ./05-create-gitops-repo.sh"
    echo "            ./06-argocd-setup.sh"
    echo ""
}

# Main execution
main() {
    check_prerequisites
    setup_kubectl
    verify_cluster
    create_namespace
    add_helm_repos
    install_postgresql
    install_redis
    install_rabbitmq
    deploy_application
    install_ingress
    verify_deployment
    print_summary

    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Helm Deployment Completed Successfully! 🎉       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main