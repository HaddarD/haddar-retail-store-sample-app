# Repository Structure and Deployment Flow

## Overview

This project uses a **two-repository GitOps architecture**:

1. **Application Repository** (`haddar-retail-store-sample-app`) - Source code, Terraform IaC, CI/CD
2. **GitOps Repository** (`gitops-retail-store-app`) - Kubernetes configurations

---

## Repository 1: Application Repository

**URL:** `https://github.com/HaddarD/haddar-retail-store-sample-app`

**Purpose:** Contains application source code, complete Terraform infrastructure, CI/CD pipeline, and automation scripts.

### Structure:
```
haddar-retail-store-sample-app/
├── terraform/                    # 🏗️ Complete Infrastructure as Code
│   ├── main.tf                   # Provider, backend, data sources
│   ├── variables.tf              # Input variables
│   ├── outputs.tf                # Exported values
│   ├── terraform.tfvars          # Configuration values
│   ├── vpc.tf                    # VPC, subnets, IGW, routes
│   ├── security-groups.tf        # Kubernetes security groups
│   ├── iam.tf                    # IAM roles and policies
│   ├── ec2.tf                    # 3 EC2 instances
│   ├── ecr.tf                    # 5 ECR repositories
│   └── dynamodb.tf               # DynamoDB table
│
├── src/                          # Microservices source code
│   ├── ui/                       # Java Spring Boot frontend
│   ├── catalog/                  # Go REST API
│   ├── cart/                     # Java Spring Boot
│   ├── orders/                   # Java Spring Boot
│   └── checkout/                 # Node.js
│
├── helm-chart/                   # Kubernetes Helm chart
├── .github/workflows/            # CI/CD pipeline
├── docs/                         # Documentation
│
├── 00-prerequisites.sh           # Check/install tools
├── 01-terraform-init.sh          # Bootstrap Terraform
├── 02-terraform-apply.sh         # Create infrastructure
├── 03-k8s-init.sh                # Setup Kubernetes + ECR auth
├── 04-helm-deploy.sh             # Deploy with Helm
├── 05-create-gitops-repo.sh      # Create GitOps repo
├── 06-argocd-setup.sh            # Install ArgoCD
├── startup.sh                    # Daily startup script
├── restore-vars.sh               # Load variables
├── Display-App-URLs.sh           # Show URLs
├── 99-cleanup.sh                 # Destroy everything
│
└── deployment-info.txt           # Generated variables (not in this repo - created by 02-terraform-apply.sh)
```

---

## Repository 2: GitOps Repository

**URL:** `https://github.com/HaddarD/gitops-retail-store-app`

**Purpose:** Single source for Kubernetes deployments via ArgoCD.

### Structure:
```
gitops-retail-store-app/
│
├── apps/                             # 📦 Helm Charts per Service
│   ├── ui/
│   │   ├── Chart.yaml
│   │   ├── values.yaml               # ← Image tags updated by CI/CD
│   │   └── templates/
│   │       ├── deployment.yaml       # No imagePullSecrets!
│   │       └── service.yaml
│   │
│   ├── catalog/
│   ├── cart/
│   ├── orders/
│   ├── checkout/
│   └── dependencies/                 # PostgreSQL, Redis, RabbitMQ
│
├── argocd/                           # 🚀 ArgoCD Application Definitions
│   └── applications/
│       ├── application-ui.yaml
│       ├── application-catalog.yaml
│       ├── application-cart.yaml
│       ├── application-orders.yaml
│       ├── application-checkout.yaml
│       └── application-dependencies.yaml
│
└── README.md
```

**Key Feature:** No `imagePullSecrets` - uses ECR Credential Helper with IAM role!

---

## Deployment Flow

### Complete CI/CD Pipeline:
```
     DEVELOPER              GITHUB ACTIONS           AWS/KUBERNETES
         │                        │                        │
    1. Push Code                 │                        │
         │                        │                        │
         ├───────────────────────▶│                        │
         │                        │                        │
         │                 2. Trigger Workflow             │
         │                        │                        │
         │                 3. Build Images                 │
         │                        │                        │
         │                        ├───────────────────────▶│
         │                        │   4. Push to ECR       │
         │                        │                        │
         │                 5. Clone GitOps                 │
         │                    Repo (if exists)             │
         │                        │                        │
         │                 6. Update image tags            │
         │                        │                        │
         │                 7. Push to GitOps               │
         │                        │                        │
         │                        │                        │
         │                        │   8. ArgoCD watches    │
         │                        │      GitOps repo       │
         │                        │                        │
         │                        │◀───────────────────────│
         │                        │   9. ArgoCD syncs      │
         │                        │                        │
         │                        │                        │
         │                        ├───────────────────────▶│
         │                        │  10. Pull images       │
         │                        │      from ECR          │
         │                        │      (IAM role auth)   │
         │                        │                        │
         │                        │  11. Deploy new pods   │
         │                        │                        │
    12. User sees                 │                        │
        updated app               │                        │
```

---

## Terraform Infrastructure Provisioning

**What Terraform Creates:**
- VPC, subnet, internet gateway, route table
- Security group (all Kubernetes ports)
- IAM role with ECR + DynamoDB policies
- Instance profile
- 3 EC2 instances (t3.medium, 20GB volumes)
- 5 ECR repositories (with lifecycle policies)
- DynamoDB table (for cart service)
- SSH key pair in AWS

**Stored in S3 Backend:**
- Bucket: `haddar-k8s-terraform-state`
- DynamoDB lock: `terraform-state-lock`
- Versioning enabled for rollback

**Usage:**
```bash
./01-terraform-init.sh     # Bootstrap S3 backend
./02-terraform-apply.sh    # Create everything
terraform show             # View current state
terraform output           # See all outputs
```

---

## ECR Credential Helper (No Token Expiration!)

**How it works:**
1. `amazon-ecr-credential-helper` installed on all 3 EC2 nodes
2. `containerd` configured to use credential helper
3. Helper uses EC2 IAM role for authentication
4. No Kubernetes secrets needed
5. No 12-hour token expiration

**Benefits:**
- ✅ Zero maintenance
- ✅ Works after EC2 downtime
- ✅ No `imagePullSecrets` in manifests
- ✅ AWS best practice

---

## Monitoring Deployment

### Check ArgoCD Applications:
```bash
kubectl get applications -n argocd
```

### Expected Output:
```
NAME                        SYNC STATUS   HEALTH STATUS
retail-store-ui             Synced        Healthy
retail-store-catalog        Synced        Healthy
retail-store-cart           Synced        Healthy
retail-store-orders         Synced        Healthy
retail-store-checkout       Synced        Healthy
retail-store-dependencies   Synced        Healthy
```

### Check Pods:
```bash
kubectl get pods -n retail-store
```

---

## Rollback Procedure

### Option 1: Git Revert (Recommended)
```bash
cd gitops-retail-store-app
git revert HEAD
git push
# ArgoCD auto-syncs to previous version
```

### Option 2: ArgoCD UI
1. Open ArgoCD dashboard
2. Select application
3. Click "History and Rollback"
4. Choose previous revision
5. Click "Rollback"

---

## Summary

| Aspect | Implementation |
|--------|----------------|
| Infrastructure | Complete Terraform IaC |
| Source Code | Application Repository |
| Configurations | GitOps Repository |
| ECR Authentication | Credential Helper (IAM role) |
| CI | GitHub Actions |
| CD | ArgoCD |
| Container Registry | AWS ECR |
| Kubernetes | kubeadm on EC2 |
| Ingress | nginx-ingress (NodePort) |