#!/bin/bash

################################################################################
# Create GitOps Repository Script - Phase 5
# Creates a separate GitHub repository for GitOps (ArgoCD) deployment
#
# This script:
# 1. Creates a new GitHub repository: gitops-retail-store-app
# 2. Generates Helm charts for each microservice
# 3. Creates ArgoCD Application manifests
# 4. Injects current deployment values (ECR URLs, DynamoDB table, region)
# 5. Pushes everything to GitHub
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
GITOPS_REPO_NAME="gitops-retail-store-app"
GITOPS_BRANCH="main"
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
echo "║   GitOps Repository Creation - Phase 5               ║"
echo "║   Create Separate Repo for ArgoCD Deployments        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check git
    if ! command -v git &> /dev/null; then
        print_error "Git not found"
        exit 1
    fi
    print_success "Git found"
    
    # Check GitHub authentication
    print_info "Checking GitHub authentication..."
    if ! git ls-remote git@github.com:$(git config user.name)/test.git &> /dev/null 2>&1; then
        print_warning "GitHub SSH authentication might not be configured"
        print_info "Make sure you can push to GitHub via SSH"
    else
        print_success "GitHub SSH authentication working"
    fi
    
    # Get GitHub username
    print_info "Getting GitHub username..."
    GITHUB_USER=$(git config user.name 2>/dev/null || echo "")
    
    if [ -z "$GITHUB_USER" ]; then
        print_warning "GitHub username not found in git config"
        read -p "Enter your GitHub username: " GITHUB_USER
    fi
    
    print_success "GitHub username: ${GITHUB_USER}"
}

# Create local GitOps repository
create_local_repo() {
    print_header "Creating Local GitOps Repository"
    
    # Remove existing directory if it exists
    if [ -d "$GITOPS_REPO_NAME" ]; then
        print_warning "Directory ${GITOPS_REPO_NAME} already exists"
        read -p "Delete and recreate? (y/n): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$GITOPS_REPO_NAME"
            print_success "Removed existing directory"
        else
            print_error "Cannot proceed with existing directory"
            exit 1
        fi
    fi
    
    mkdir -p "$GITOPS_REPO_NAME"
    cd "$GITOPS_REPO_NAME"
    
    git init
    git checkout -b "$GITOPS_BRANCH" 2>/dev/null || git checkout "$GITOPS_BRANCH"
    
    print_success "Local repository initialized"
}

# Create directory structure
create_directory_structure() {
    print_header "Creating Directory Structure"
    
    mkdir -p apps/{ui,catalog,cart,orders,checkout,dependencies}/templates
    mkdir -p argocd/applications
    
    print_success "Directory structure created"
}

# Create Helm chart for UI service
create_ui_chart() {
    print_info "Creating UI service chart..."
    
    # Chart.yaml
    cat > apps/ui/Chart.yaml << EOF
apiVersion: v2
name: ui
description: Retail Store UI Service
type: application
version: 1.0.0
appVersion: "1.0.0"
EOF
    
    # values.yaml
    cat > apps/ui/values.yaml << EOF
name: ui
replicaCount: 1

image:
  repository: ${ECR_UI_REPO}
  tag: latest
  pullPolicy: Always

# No imagePullSecrets - using ECR Credential Helper (Option B)

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"

env:
  - name: CATALOG_ENDPOINT
    value: "http://catalog:80"
  - name: CARTS_ENDPOINT
    value: "http://cart:80"
  - name: ORDERS_ENDPOINT
    value: "http://orders:80"
  - name: CHECKOUT_ENDPOINT
    value: "http://checkout:80"
EOF
    
    # Deployment template
    cat > apps/ui/templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.name }}
    spec:
      containers:
      - name: {{ .Values.name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
        env:
        {{- range .Values.env }}
        - name: {{ .name }}
          value: {{ .value | quote }}
        {{- end }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
EOF
    
    # Service template
    cat > apps/ui/templates/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
    protocol: TCP
  selector:
    app: {{ .Values.name }}
EOF
    
    print_success "UI chart created"
}

# Create similar charts for other services
create_service_charts() {
    print_info "Creating service charts..."
    
    # Catalog
    create_service_chart "catalog" "$ECR_CATALOG_REPO" \
        "DB_ENDPOINT:postgresql.retail-store.svc.cluster.local:5432,DB_NAME:catalog,DB_USER:postgres,DB_PASSWORD:postgres" \
        "256Mi" "100m" "256Mi" "200m"
    
    # Cart
    create_service_chart "cart" "$ECR_CART_REPO" \
        "REDIS_ENDPOINT:redis-master.retail-store.svc.cluster.local:6379,CARTS_DYNAMODB_TABLENAME:${DYNAMODB_TABLE_NAME},AWS_DEFAULT_REGION:${REGION}" \
        "512Mi" "250m" "1Gi" "500m"
    
    # Orders
    create_service_chart "orders" "$ECR_ORDERS_REPO" \
        "DB_ENDPOINT:postgresql.retail-store.svc.cluster.local:5432,DB_NAME:catalog,DB_USER:postgres,DB_PASSWORD:postgres" \
        "512Mi" "250m" "1Gi" "500m"
    
    # Checkout
    create_service_chart "checkout" "$ECR_CHECKOUT_REPO" \
        "ORDERS_ENDPOINT:http://orders:80,CARTS_ENDPOINT:http://cart:80,RABBITMQ_ENDPOINT:rabbitmq.retail-store.svc.cluster.local:5672,RABBITMQ_USERNAME:guest,RABBITMQ_PASSWORD:guest" \
        "256Mi" "100m" "512Mi" "200m"
}

create_service_chart() {
    local SERVICE=$1
    local REPO=$2
    local ENV_VARS=$3
    local REQ_MEM=$4
    local REQ_CPU=$5
    local LIM_MEM=$6
    local LIM_CPU=$7
    
    # Chart.yaml
    cat > apps/${SERVICE}/Chart.yaml << EOF
apiVersion: v2
name: ${SERVICE}
description: Retail Store ${SERVICE^} Service
type: application
version: 1.0.0
appVersion: "1.0.0"
EOF
    
    # values.yaml
    cat > apps/${SERVICE}/values.yaml << EOF
name: ${SERVICE}
replicaCount: 1

image:
  repository: ${REPO}
  tag: latest
  pullPolicy: Always

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

resources:
  requests:
    memory: "${REQ_MEM}"
    cpu: "${REQ_CPU}"
  limits:
    memory: "${LIM_MEM}"
    cpu: "${LIM_CPU}"

env:
EOF
    
    # Add environment variables
    IFS=',' read -ra VARS <<< "$ENV_VARS"
    for VAR in "${VARS[@]}"; do
        IFS=':' read -ra KV <<< "$VAR"
        cat >> apps/${SERVICE}/values.yaml << EOF
  - name: ${KV[0]}
    value: "${KV[1]}"
EOF
    done
    
    # Deployment template (same as UI)
    cat > apps/${SERVICE}/templates/deployment.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      app: {{ .Values.name }}
  template:
    metadata:
      labels:
        app: {{ .Values.name }}
    spec:
      containers:
      - name: {{ .Values.name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - containerPort: {{ .Values.service.targetPort }}
        env:
        {{- range .Values.env }}
        - name: {{ .name }}
          value: {{ .value | quote }}
        {{- end }}
        resources:
          {{- toYaml .Values.resources | nindent 10 }}
EOF
    
    # Service template (same as UI)
    cat > apps/${SERVICE}/templates/service.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Values.name }}
  namespace: {{ .Release.Namespace }}
spec:
  type: {{ .Values.service.type }}
  ports:
  - port: {{ .Values.service.port }}
    targetPort: {{ .Values.service.targetPort }}
    protocol: TCP
  selector:
    app: {{ .Values.name }}
EOF
}

# Create dependencies chart (PostgreSQL, Redis, RabbitMQ)
create_dependencies_chart() {
    print_info "Creating dependencies chart..."
    
    cat > apps/dependencies/Chart.yaml << EOF
apiVersion: v2
name: dependencies
description: Retail Store Dependencies (PostgreSQL, Redis, RabbitMQ)
type: application
version: 1.0.0
appVersion: "1.0.0"
dependencies:
  - name: postgresql
    version: 12.x.x
    repository: https://charts.bitnami.com/bitnami
  - name: redis
    version: 17.x.x
    repository: https://charts.bitnami.com/bitnami
  - name: rabbitmq
    version: 11.x.x
    repository: https://charts.bitnami.com/bitnami
EOF
    
    cat > apps/dependencies/values.yaml << EOF
postgresql:
  auth:
    username: postgres
    password: postgres
    database: catalog
  primary:
    persistence:
      enabled: false

redis:
  auth:
    enabled: false
  master:
    persistence:
      enabled: false
  replica:
    persistence:
      enabled: false

rabbitmq:
  auth:
    username: guest
    password: guest
  persistence:
    enabled: false
  replicaCount: 1
  resources:
    requests:
      memory: 512Mi
      cpu: 250m
EOF
    
    print_success "Dependencies chart created"
}

# Create ArgoCD Application manifests
create_argocd_applications() {
    print_header "Creating ArgoCD Application Manifests"
    
    for SERVICE in ui catalog cart orders checkout dependencies; do
        cat > argocd/applications/application-${SERVICE}.yaml << EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: retail-store-${SERVICE}
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/${GITHUB_USER}/${GITOPS_REPO_NAME}.git
    targetRevision: ${GITOPS_BRANCH}
    path: apps/${SERVICE}
    helm:
      valueFiles:
        - values.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: ${NAMESPACE}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
        print_success "Created ArgoCD application for ${SERVICE}"
    done
}

# Create README
create_readme() {
    print_info "Creating README..."
    
    cat > README.md << EOF
# GitOps Retail Store Application

This repository contains Kubernetes manifests managed by ArgoCD for the Retail Store application.

## Repository Structure

\`\`\`
gitops-retail-store-app/
├── apps/
│   ├── ui/              # UI Service Helm Chart
│   ├── catalog/         # Catalog Service
│   ├── cart/            # Cart Service  
│   ├── orders/          # Orders Service
│   ├── checkout/        # Checkout Service
│   └── dependencies/    # PostgreSQL, Redis, RabbitMQ
│
└── argocd/
    └── applications/    # ArgoCD Application Definitions
\`\`\`

## How It Works

1. **GitHub Actions** builds Docker images → pushes to ECR
2. **GitHub Actions** updates image tags in this repo
3. **ArgoCD** watches this repo for changes
4. **ArgoCD** automatically syncs changes to Kubernetes cluster

## Important Notes

- Images pulled from ECR using **ECR Credential Helper** (Option B)
- No imagePullSecrets needed - IAM role handles authentication
- All deployments target namespace: \`retail-store\`

## Deployment Values

Current deployment configuration:
- ECR Registry: \`${ECR_REGISTRY}\`
- DynamoDB Table: \`${DYNAMODB_TABLE_NAME}\`
- AWS Region: \`${REGION}\`
EOF
    
    print_success "README created"
}

# Push to GitHub
push_to_github() {
    print_header "Pushing to GitHub"
    
    print_info "Adding files to git..."
    git add .
    git commit -m "Initial GitOps repository structure"
    
    print_info "Creating remote repository..."
    print_warning "You need to create the repository on GitHub manually:"
    echo ""
    echo "1. Go to: https://github.com/new"
    echo "2. Repository name: ${GITOPS_REPO_NAME}"
    echo "3. Make it Public or Private (your choice)"
    echo "4. DO NOT initialize with README"
    echo "5. Click 'Create repository'"
    echo ""
    read -p "Press Enter when repository is created..."
    
    print_info "Adding remote origin..."
    git remote add origin git@github.com:${GITHUB_USER}/${GITOPS_REPO_NAME}.git
    
    print_info "Pushing to GitHub..."
    git push -u origin "$GITOPS_BRANCH"
    
    print_success "Pushed to GitHub"
}

# Update main repo deployment-info.txt
update_deployment_info() {
    print_header "Updating deployment-info.txt"
    
    cd ..
    
    # Add GitOps variables
    cat >> deployment-info.txt << EOF

# GitOps Configuration
export GITOPS_REPO_URL="https://github.com/${GITHUB_USER}/${GITOPS_REPO_NAME}.git"
export GITOPS_REPO_NAME="${GITOPS_REPO_NAME}"
export GITOPS_BRANCH="${GITOPS_BRANCH}"
export GITHUB_USER="${GITHUB_USER}"
EOF
    
    print_success "deployment-info.txt updated"
}

# Print summary
print_summary() {
    print_header "GitOps Repository Created Successfully!"
    
    echo -e "${GREEN}✅ GitOps repository is ready!${NC}"
    echo ""
    echo -e "${BLUE}Repository Details:${NC}"
    echo "  Name:   ${GITOPS_REPO_NAME}"
    echo "  URL:    https://github.com/${GITHUB_USER}/${GITOPS_REPO_NAME}"
    echo "  Branch: ${GITOPS_BRANCH}"
    echo ""
    echo -e "${CYAN}What was created:${NC}"
    echo "  • 5 microservice Helm charts (ui, catalog, cart, orders, checkout)"
    echo "  • 1 dependencies chart (PostgreSQL, Redis, RabbitMQ)"
    echo "  • 6 ArgoCD Application manifests"
    echo "  • All values pre-configured with current deployment info"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "  • Images will be pulled using ECR Credential Helper"
    echo "  • No imagePullSecrets needed in any manifests"
    echo "  • IAM role handles ECR authentication automatically"
    echo ""
    echo -e "${BLUE}Next Steps:${NC}"
    echo "  1. Install ArgoCD:  ./06-argocd-setup.sh"
    echo "  2. ArgoCD will watch this GitOps repo"
    echo "  3. Any changes to GitOps repo auto-deploy to cluster"
}

# Main execution
main() {
    check_prerequisites
    create_local_repo
    create_directory_structure
    create_ui_chart
    create_service_charts
    create_dependencies_chart
    create_argocd_applications
    create_readme
    push_to_github
    update_deployment_info
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   GitOps Repository Created Successfully! 🎉         ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
