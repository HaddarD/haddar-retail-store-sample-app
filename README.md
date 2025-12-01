# Haddar's Retail Store - Kubernetes kubeadm Cluster 🛒

A microservices e-commerce application deployed on a self-managed Kubernetes cluster using kubeadm, with complete infrastructure automation via Terraform and GitOps continuous deployment via ArgoCD.

## Features

- 🏗️ **Complete Infrastructure as Code** - Terraform provisions ALL AWS resources
- 🏛️ **Self-managed Kubernetes** cluster using kubeadm (not EKS)
- 🐳 **5 Microservices**: UI, Catalog, Cart, Orders, Checkout
- 📦 **AWS ECR** with automatic authentication (no token expiration!)
- 🔄 **GitHub Actions CI/CD** pipeline
- 🚀 **ArgoCD GitOps** for automated deployments
- 📊 **Automated bash scripts** for daily operations

## Architecture
```
┌─────────────────────────────────────────────────────────────────┐
│                         AWS Cloud                                │
│                                                                  │
│   ┌──────────┐     ┌──────────┐     ┌──────────┐               │
│   │  Master  │     │ Worker1  │     │ Worker2  │               │
│   │ t3.medium│     │ t3.medium│     │ t3.medium│               │
│   └────┬─────┘     └────┬─────┘     └────┬─────┘               │
│        └────────────────┴────────────────┘                      │
│                    Kubernetes Cluster                            │
│                                                                  │
│   ┌─────────────────────────────────────────────────────────┐  │
│   │  UI → Catalog → Cart → Checkout → Orders                │  │
│   │        ↓          ↓        ↓          ↓                 │  │
│   │   PostgreSQL    Redis   RabbitMQ   PostgreSQL           │  │
│   │                   ↓                                      │  │
│   │               DynamoDB (AWS)                             │  │
│   └─────────────────────────────────────────────────────────┘  │
│                                                                  │
│   ┌──────────┐    ┌──────────┐    ┌──────────┐                 │
│   │   ECR    │    │  ArgoCD  │    │Terraform │                 │
│   │(registry)│    │ (GitOps) │    │   (ALL)  │                 │
│   └──────────┘    └──────────┘    └──────────┘                 │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS CLI configured with appropriate permissions
- GitHub account with repository access
- Bash terminal (Linux/macOS/WSL)
- ~$3-6/day AWS costs (3x t3.medium EC2 instances)

## Quick Start 🚀

### First Time Setup
```bash
# 1. Clone the repository
git clone https://github.com/HaddarD/haddar-retail-store-sample-app.git
cd haddar-retail-store-sample-app

# 2. Check/install prerequisites (Terraform, Helm, kubectl, etc.)
./00-prerequisites.sh

# 3. Generate SSH key for EC2 instances
ssh-keygen -t rsa -b 4096 -f haddar-k8s-kubeadm-key -N ""

# 4. Bootstrap Terraform backend (S3 + DynamoDB)
./01-terraform-init.sh

# 5. Create ALL infrastructure (VPC, EC2, ECR, DynamoDB, IAM)
./02-terraform-apply.sh

# 6. Load environment variables
source restore-vars.sh

# 7. Initialize Kubernetes cluster + ECR authentication
./03-k8s-init.sh

# 8. Push your code to GitHub (needed for ArgoCD later)
git add .
git commit -m "Initial setup"
git push origin main

# 9. Deploy with Helm (Phase 4 demonstration)
./04-helm-deploy.sh

# 10. Create GitOps repository (Phase 5)
./05-create-gitops-repo.sh
# Add GITOPS_PAT secret to GitHub repository settings

# 11. Install ArgoCD (takes over from Helm)
./06-argocd-setup.sh
```

### Daily Startup
```bash
./startup.sh && source restore-vars.sh
```

### Access the Application
```bash
./Display-App-URLs.sh

# Or manually:
# Retail Store: http://<MASTER_IP>:30080
# ArgoCD UI: https://<MASTER_IP>:30090
```

## Project Structure
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
└── deployment-info.txt           # Generated variables
```

## Scripts Reference

| Script | Purpose | When to Run |
|--------|---------|-------------|
| `00-prerequisites.sh` | Install tools (Terraform, Helm, etc.) | Once |
| `01-terraform-init.sh` | Bootstrap S3 backend for Terraform | Once |
| `02-terraform-apply.sh` | Create ALL AWS infrastructure | Once |
| `03-k8s-init.sh` | Initialize K8s + ECR Credential Helper | Once |
| `04-helm-deploy.sh` | Deploy app with Helm (Phase 4) | Once |
| `05-create-gitops-repo.sh` | Create GitOps repository | Once |
| `06-argocd-setup.sh` | Install ArgoCD (Phase 5) | Once |
| `startup.sh` | Start EC2s, update IPs | Every session |
| `restore-vars.sh` | Load environment variables | Every session |
| `Display-App-URLs.sh` | Show application URLs | Anytime |
| `99-cleanup.sh` | Destroy ALL resources | End of project |

## GitHub Secrets Required

Add these to your GitHub repository settings → Secrets and variables → Actions:

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key |
| `GITOPS_PAT` | GitHub Personal Access Token (for GitOps repo) |

## What's New: Terraform + ECR Credential Helper

**Complete Terraform Infrastructure:**
- Everything is now created via Terraform (VPC, EC2, ECR, DynamoDB, IAM)
- Stored in S3 backend with DynamoDB locking
- One command to create, one command to destroy

**ECR Credential Helper (No More Token Expiration!):**
- Uses EC2 IAM role for authentication
- No imagePullSecrets needed
- No 12-hour token refresh required
- Images pull automatically from ECR

## Useful Commands
```bash
# Check cluster status
kubectl get nodes
kubectl get pods -n retail-store

# Check ArgoCD applications
kubectl get applications -n argocd

# View application logs
kubectl logs -n retail-store -l app=ui --tail=50

# SSH to master node
ssh -i haddar-k8s-kubeadm-key ubuntu@$MASTER_PUBLIC_IP

# Terraform commands
cd terraform
terraform plan        # Show what would change
terraform show        # Show current state
terraform output      # Show all outputs
```

## Troubleshooting

### Pods stuck in ImagePullBackOff
ECR Credential Helper should handle this automatically. If issues persist:
```bash
# Check IAM role is attached
aws ec2 describe-instances --instance-ids $MASTER_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].IamInstanceProfile'

# Verify credential helper is installed
ssh -i haddar-k8s-kubeadm-key ubuntu@$MASTER_PUBLIC_IP \
  "docker-credential-ecr-login -v"
```

### Cannot connect to cluster
```bash
./startup.sh && source restore-vars.sh
```

### Terraform state issues
```bash
cd terraform
terraform init -reconfigure
```

## Cleanup

**⚠️ This deletes ALL resources!**
```bash
./99-cleanup.sh
```

## Technologies Used

- **Cloud:** AWS (EC2, VPC, ECR, DynamoDB, S3, IAM)
- **IaC:** Terraform (complete infrastructure)
- **Container Runtime:** containerd + ECR Credential Helper
- **Kubernetes:** kubeadm 1.28, Calico CNI
- **Package Manager:** Helm
- **GitOps:** ArgoCD
- **CI/CD:** GitHub Actions

## Documentation

- [Environment Configurations](docs/environment-configurations.md)
- [Repository Structure & Deployment Flow](docs/repository-structure-and-deployment-flow.md)
- [Reflections](docs/reflections.md)

---

*DevOps project demonstrating Terraform IaC, Kubernetes, CI/CD, and GitOps* 🎓