#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Helm Deployment Script
# Phase 4: Deploy all microservices and dependencies using Helm
################################################################################

set -e

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

    if ! command -v helm &> /dev/null; then
        print_error "Helm not found. Please run: ./00-prerequisites.sh"
        exit 1
    fi
    HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
    print_success "Helm installed: ${HELM_VERSION}"

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found"
        exit 1
    fi
    print_success "kubectl installed"

    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key not found: $KEY_FILE"
        exit 1
    fi
    print_success "SSH key found"

    print_info "Configuring kubectl..."
    mkdir -p ~/.kube
    scp -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP:~/.kube/config ~/.kube/config-retail-store 2>/dev/null
    sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|g" ~/.kube/config-retail-store
    export KUBECONFIG=~/.kube/config-retail-store
    kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true

    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    if [ "$NODE_COUNT" -lt 3 ]; then
        print_error "Cluster has only $NODE_COUNT node(s). Expected 3"
        exit 1
    fi
    print_success "Cluster has $NODE_COUNT nodes"
}

create_namespace() {
    print_header "Creating Namespace"

    if kubectl get namespace $NAMESPACE &> /dev/null; then
        print_warning "Namespace '${NAMESPACE}' already exists"
        # Add Helm labels to existing namespace
        kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm --overwrite 2>/dev/null
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=retail-store --overwrite 2>/dev/null
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=retail-store --overwrite 2>/dev/null
        print_info "Helm labels added to namespace"
    else
        kubectl create namespace $NAMESPACE
        # Add Helm labels to new namespace
        kubectl label namespace $NAMESPACE app.kubernetes.io/managed-by=Helm
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-name=retail-store
        kubectl annotate namespace $NAMESPACE meta.helm.sh/release-namespace=retail-store
        print_success "Namespace created with Helm labels"
    fi
}

add_helm_repos() {
    print_header "Adding Helm Repositories"

    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || print_info "Bitnami repo exists"
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || print_info "Ingress repo exists"
    helm repo update
    print_success "Helm repositories configured"
}

install_postgresql() {
    print_header "Installing PostgreSQL (for Catalog & Orders)"

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

install_redis() {
    print_header "Installing Redis (for Cart)"

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

install_rabbitmq() {
    print_header "Installing RabbitMQ (for Checkout)"

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

    print_info "Waiting for RabbitMQ..."
    kubectl wait --for=condition=available --timeout=300s deployment/rabbitmq -n $NAMESPACE

    print_success "RabbitMQ deployed"
}

deploy_application() {
    print_header "Deploying Retail Store Application"

    print_info "Deploying microservices..."

    helm upgrade --install retail-store ./helm-chart \
        --namespace $NAMESPACE \
        --set global.ecr.registry=$ECR_REGISTRY \
        --set global.dynamodb.tableName=$DYNAMODB_TABLE_NAME \
        --set global.dynamodb.region=$REGION \
        --wait --timeout=10m

    print_success "Application deployed"
}

install_ingress() {
    print_header "Installing nginx-ingress Controller"

    kubectl create namespace ingress-nginx 2>/dev/null || true

    print_info "Deploying nginx-ingress..."
    helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30080 \
        --set controller.service.nodePorts.https=30443 \
        --wait --timeout=5m

    print_success "nginx-ingress installed"
}

verify_deployment() {
    print_header "Verifying Deployment"

    kubectl get pods -n $NAMESPACE

    print_info "Waiting for pods to be ready..."
    kubectl wait --for=condition=ready pod --all -n $NAMESPACE --timeout=300s 2>/dev/null || print_warning "Some pods still starting"

    echo ""
    kubectl get svc -n $NAMESPACE
}

print_summary() {
    print_header "Deployment Complete!"

    echo -e "${GREEN}✅ Application deployed with Helm!${NC}"
    echo ""
    echo -e "${CYAN}🛒 Access Application:${NC}"
    echo -e "   ${GREEN}http://${MASTER_PUBLIC_IP}:30080${NC}"
    echo ""
    echo -e "${YELLOW}Useful Commands:${NC}"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  kubectl logs -n ${NAMESPACE} -l app=ui --tail=50"
    echo "  helm list -n ${NAMESPACE}"
    echo ""
}

# Main execution
main() {
    check_prerequisites
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

main