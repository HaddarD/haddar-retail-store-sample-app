#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Helm Deployment Script
# Chat 4: Deploy all microservices and dependencies using Helm
#
# UPDATED with:
# - Longer timeouts (10 min)
# - Smart pod status checks
# - Auto-cleanup of failed installations
# - Worker node verification
################################################################################

set -e

# Load environment variables
if [ ! -f deployment-info.txt ]; then
    echo "❌ ERROR: deployment-info.txt not found!"
    echo "Please run 01-infrastructure.sh first"
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
        print_error "Helm not found. Please run: ./install-helm-local.sh"
        exit 1
    fi
    HELM_VERSION=$(helm version --short 2>/dev/null || helm version --template='{{.Version}}' 2>/dev/null)
    print_success "Helm installed: ${HELM_VERSION}"

    if ! command -v kubectl &> /dev/null; then
        print_error "kubectl not found. Please install kubectl first."
        exit 1
    fi
    print_success "kubectl installed"

    if [ ! -f "$KEY_FILE" ]; then
        print_error "SSH key not found: $KEY_FILE"
        exit 1
    fi
    print_success "SSH key found"

    print_info "Testing SSH connectivity to master..."
    if ! ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP "echo 'SSH OK'" &> /dev/null; then
        print_error "Cannot connect to master node at ${MASTER_PUBLIC_IP}"
        print_info "Have you run ./startup.sh to start the instances?"
        exit 1
    fi
    print_success "Master node reachable"

    if [ ! -d "${HELM_CHART_DIR}" ]; then
        print_error "Helm chart directory not found: ${HELM_CHART_DIR}"
        print_info "Please ensure helm-chart/ directory exists in project root"
        exit 1
    fi
    print_success "Helm chart found: ${HELM_CHART_DIR}"

    print_info "Configuring kubectl..."
    mkdir -p ~/.kube
    scp -o StrictHostKeyChecking=no -i "$KEY_FILE" ubuntu@$MASTER_PUBLIC_IP:~/.kube/config ~/.kube/config-retail-store 2>/dev/null
    sed -i "s|server: https://.*:6443|server: https://${MASTER_PUBLIC_IP}:6443|g" ~/.kube/config-retail-store
    export KUBECONFIG=~/.kube/config-retail-store
    kubectl config set-cluster kubernetes --insecure-skip-tls-verify=true

    print_info "Checking cluster node count..."
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

    if [ "$NODE_COUNT" -lt 3 ]; then
        print_error "Cluster has only $NODE_COUNT node(s). Expected 3"
        echo ""
        kubectl get nodes
        echo ""
        print_error "Worker nodes not joined!"
        echo ""
        echo -e "${YELLOW}To fix:${NC}"
        echo "1. Get join command:"
        echo -e "   ${CYAN}ssh -i $KEY_FILE ubuntu@$MASTER_PUBLIC_IP \"sudo kubeadm token create --print-join-command\"${NC}"
        echo "2. Join workers with that command"
        echo "3. Re-run this script"
        exit 1
    fi

    print_success "Cluster has $NODE_COUNT nodes"
    echo ""
    kubectl get nodes
    echo ""

    if [ -z "$DYNAMODB_TABLE_NAME" ]; then
        print_warning "DynamoDB table not configured"
        echo -n "Continue without DynamoDB? [y/n]: "
        read -r response
        if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
            exit 1
        fi
        print_info "Continuing without DynamoDB..."
    else
        print_success "DynamoDB table configured: ${DYNAMODB_TABLE_NAME}"
    fi
}

configure_kubectl() {
    print_header "Configuring kubectl Access"
    print_success "kubectl already configured"
    print_info "Using: ~/.kube/config-retail-store"
}

create_namespace() {
    print_header "Creating Kubernetes Namespace"

    if kubectl get namespace ${NAMESPACE} &> /dev/null; then
        print_warning "Namespace already exists: ${NAMESPACE}"
    else
        kubectl create namespace ${NAMESPACE}
        print_success "Namespace created: ${NAMESPACE}"
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

    POSTGRES_RUNNING=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql --no-headers 2>/dev/null | grep "Running" | wc -l)
    POSTGRES_RUNNING=${POSTGRES_RUNNING:-0}

    if [ "$POSTGRES_RUNNING" -gt 0 ]; then
        print_success "PostgreSQL already running"
        return
    fi

    if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^postgresql"; then
        print_warning "PostgreSQL release exists but not running"
        print_info "Cleaning up..."
        helm uninstall postgresql -n ${NAMESPACE} 2>/dev/null || true
        sleep 10
    fi

    print_info "Installing PostgreSQL (5-10 minutes)..."

    if helm install postgresql bitnami/postgresql \
        --namespace ${NAMESPACE} \
        --set auth.postgresPassword=postgres \
        --set auth.database=catalog \
        --set primary.persistence.enabled=false \
        --set volumePermissions.enabled=true \
        --wait \
        --timeout 10m; then
        print_success "PostgreSQL installed"
    else
        print_error "PostgreSQL installation failed"
        kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=postgresql
        exit 1
    fi
}

install_redis() {
    print_header "Installing Redis (for Cart)"

    REDIS_RUNNING=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=redis --no-headers 2>/dev/null | grep "Running" | wc -l)
    REDIS_RUNNING=${REDIS_RUNNING:-0}

    if [ "$REDIS_RUNNING" -gt 0 ]; then
        print_success "Redis already running"
        return
    fi

    if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^redis"; then
        print_warning "Redis release exists but not running"
        print_info "Cleaning up..."
        helm uninstall redis -n ${NAMESPACE} 2>/dev/null || true
        sleep 10
    fi

    print_info "Installing Redis (5-10 minutes)..."

    if helm install redis bitnami/redis \
        --namespace ${NAMESPACE} \
        --set auth.enabled=false \
        --set master.persistence.enabled=false \
        --set replica.replicaCount=0 \
        --set replica.persistence.enabled=false \
        --wait \
        --timeout 10m; then
        print_success "Redis installed"
    else
        print_error "Redis installation failed"
        kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=redis
        exit 1
    fi
}

install_rabbitmq() {
    print_header "Installing RabbitMQ (for Checkout)"

    RABBITMQ_RUNNING=$(kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=rabbitmq --no-headers 2>/dev/null | grep "Running" | wc -l)
    RABBITMQ_RUNNING=${RABBITMQ_RUNNING:-0}

    if [ "$RABBITMQ_RUNNING" -gt 0 ]; then
        print_success "RabbitMQ already running"
        return
    fi

    if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^rabbitmq"; then
        print_warning "RabbitMQ release exists but not running"
        print_info "Cleaning up..."
        helm uninstall rabbitmq -n ${NAMESPACE} 2>/dev/null || true
        sleep 10
    fi

    print_info "Installing RabbitMQ (5-20 minutes)..."

    if helm install rabbitmq bitnami/rabbitmq \
        --namespace ${NAMESPACE} \
        --set auth.username=guest \
        --set auth.password=guest \
        --set persistence.enabled=false \
        --wait \
        --timeout 20m; then
        print_success "RabbitMQ installed"
    else
        print_error "RabbitMQ installation failed"
        kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=rabbitmq
        exit 1
    fi
}

deploy_applications() {
    print_header "Deploying Retail Store Applications"

    RETAIL_RUNNING=$(kubectl get pods -n ${NAMESPACE} -l 'app in (ui,catalog,cart,orders,checkout)' --no-headers 2>/dev/null | grep "Running" | wc -l)
    RETAIL_RUNNING=${RETAIL_RUNNING:-0}

    if [ "$RETAIL_RUNNING" -ge 5 ]; then
        print_success "Retail store already running (5/5 services)"
        return
    fi

    if helm list -n ${NAMESPACE} 2>/dev/null | grep -q "^retail-store"; then
        print_warning "Retail store exists ($RETAIL_RUNNING/5 running)"
        print_info "Upgrading..."

        helm upgrade retail-store ./${HELM_CHART_DIR} \
            --namespace ${NAMESPACE} \
            --set global.ecr.registry=${ECR_REGISTRY} \
            --set global.dynamodb.tableName=${DYNAMODB_TABLE_NAME:-""} \
            --set global.dynamodb.region=${DYNAMODB_REGION:-us-east-1} \
            --wait \
            --timeout 10m

        print_success "Retail store upgraded"
    else
        print_info "Installing retail store (5-10 minutes)..."

        if helm install retail-store ./${HELM_CHART_DIR} \
            --namespace ${NAMESPACE} \
            --set global.ecr.registry=${ECR_REGISTRY} \
            --set global.dynamodb.tableName=${DYNAMODB_TABLE_NAME:-""} \
            --set global.dynamodb.region=${DYNAMODB_REGION:-us-east-1} \
            --wait \
            --timeout 10m; then
            print_success "Retail store installed"
        else
            print_error "Retail store installation failed"
            kubectl get pods -n ${NAMESPACE}
            exit 1
        fi
    fi
}

install_ingress() {
    print_header "Installing NGINX Ingress Controller"

    INGRESS_RUNNING=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep "Running" | wc -l)
    INGRESS_RUNNING=${INGRESS_RUNNING:-0}

    if [ "$INGRESS_RUNNING" -gt 0 ]; then
        print_success "NGINX Ingress already running"
        return
    fi

    if helm list -n ingress-nginx 2>/dev/null | grep -q "^ingress-nginx"; then
        print_warning "Ingress release exists but not running"
        print_info "Cleaning up..."
        helm uninstall ingress-nginx -n ingress-nginx 2>/dev/null || true
        sleep 10
    fi

    kubectl create namespace ingress-nginx 2>/dev/null || print_info "Namespace exists"

    print_info "Installing NGINX Ingress..."

    if helm install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.service.type=NodePort \
        --set controller.service.nodePorts.http=30080 \
        --set controller.service.nodePorts.https=30443 \
        --wait \
        --timeout 10m; then
        print_success "NGINX Ingress installed"
    else
        print_error "Ingress installation failed"
        kubectl get pods -n ingress-nginx
        exit 1
    fi
}

verify_deployment() {
    print_header "Verifying Deployment"

    echo ""
    kubectl get pods -n ${NAMESPACE}
    echo ""

    print_info "Waiting for pods (timeout: 5 minutes)..."

    TIMEOUT=300
    ELAPSED=0
    while [ $ELAPSED -lt $TIMEOUT ]; do
        NOT_READY=$(kubectl get pods -n ${NAMESPACE} --no-headers 2>/dev/null | grep -v "Running\|Completed" | wc -l)

        if [ "$NOT_READY" -eq 0 ]; then
            print_success "All pods ready!"
            break
        fi

        sleep 10
        ELAPSED=$((ELAPSED + 10))
        print_info "Waiting... ($ELAPSED/$TIMEOUT seconds)"
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
        print_warning "Timeout. Some pods may not be ready."
    fi

    echo ""
    kubectl get svc -n ${NAMESPACE}
    echo ""
}

update_deployment_info() {
    print_header "Updating deployment-info.txt"

    if ! grep -q "# Helm Deployment" deployment-info.txt; then
        echo "" >> deployment-info.txt
        echo "# Helm Deployment" >> deployment-info.txt
    fi

    if grep -q "^export NAMESPACE=" deployment-info.txt; then
        sed -i "s|^export NAMESPACE=.*|export NAMESPACE=\"${NAMESPACE}\"|" deployment-info.txt
    else
        echo "export NAMESPACE=\"${NAMESPACE}\"" >> deployment-info.txt
    fi

    if grep -q "^export KUBECONFIG=" deployment-info.txt; then
        sed -i "s|^export KUBECONFIG=.*|export KUBECONFIG=\"~/.kube/config-retail-store\"|" deployment-info.txt
    else
        echo "export KUBECONFIG=\"~/.kube/config-retail-store\"" >> deployment-info.txt
    fi

    print_success "deployment-info.txt updated"
}

print_summary() {
    print_header "Deployment Complete!"

    echo -e "${GREEN}✅ All services deployed!${NC}"
    echo ""
    echo -e "${BLUE}Services:${NC}"
    echo "  • PostgreSQL, Redis, RabbitMQ"
    echo "  • UI, Catalog, Cart, Orders, Checkout"
    echo "  • NGINX Ingress"
    echo ""
    echo -e "${BLUE}Access:${NC}"
    echo -e "  ${CYAN}http://${MASTER_PUBLIC_IP}:30080${NC}"
    echo ""
    echo -e "${BLUE}Commands:${NC}"
    echo "  export KUBECONFIG=~/.kube/config-retail-store"
    echo "  kubectl get pods -n ${NAMESPACE}"
    echo "  helm list -n ${NAMESPACE}"
    echo ""
}

main() {
    check_prerequisites
    configure_kubectl
    create_namespace
    add_helm_repos
    install_postgresql
    install_redis
    install_rabbitmq
    deploy_applications
    install_ingress
    verify_deployment
    update_deployment_info
    print_summary

    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║      Helm Deployment Completed Successfully! 🎉       ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

main