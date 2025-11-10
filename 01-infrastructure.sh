#!/bin/bash

################################################################################
# Kubernetes kubeadm Cluster - Infrastructure Setup Script
# This script creates all AWS resources needed for the K8s cluster:
# - 3 EC2 instances (1 master, 2 workers)
# - Security group with K8s ports
# - IAM role for ECR access
# - SSH key pair
################################################################################

set -e  # Exit on any error

# Configuration
PROJECT_NAME="k8s-kubeadm"
KEY_NAME="${PROJECT_NAME}-key"
SECURITY_GROUP_NAME="${PROJECT_NAME}-sg"
IAM_ROLE_NAME="${PROJECT_NAME}-ecr-role"
IAM_INSTANCE_PROFILE_NAME="${PROJECT_NAME}-ecr-profile"
REGION="us-east-1"
INSTANCE_TYPE="t3.medium"
AMI_ID=""  # Will be auto-detected for Ubuntu 24.04

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

# Check prerequisites
check_prerequisites() {
    print_header "Checking Prerequisites"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        print_error "AWS CLI not found. Please install it first."
        exit 1
    fi
    print_success "AWS CLI installed"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured. Run 'aws configure' first."
        exit 1
    fi
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    print_success "AWS credentials configured (Account: ${ACCOUNT_ID})"
    
    # Check jq
    if ! command -v jq &> /dev/null; then
        print_warning "jq not found. Installing it is recommended for better output parsing."
        print_info "Install with: sudo apt-get install jq"
    else
        print_success "jq installed"
    fi
}

# Get Ubuntu 24.04 AMI
get_ubuntu_ami() {
    print_header "Getting Ubuntu 24.04 AMI"
    
    print_info "Looking up latest Ubuntu 24.04 LTS AMI..."
    AMI_ID=$(aws ec2 describe-images \
        --owners 099720109477 \
        --filters "Name=name,Values=ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*" \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
        --output text \
        --region ${REGION})
    
    if [ -z "$AMI_ID" ] || [ "$AMI_ID" = "None" ]; then
        print_error "Failed to find Ubuntu 24.04 AMI"
        exit 1
    fi
    
    print_success "Found Ubuntu 24.04 AMI: ${AMI_ID}"
}

# Create SSH key pair
create_ssh_key() {
    print_header "Creating SSH Key Pair"
    
    # Check if key already exists in AWS
    if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region ${REGION} &> /dev/null; then
        print_warning "Key pair already exists in AWS: ${KEY_NAME}"
        
        # Check if local file exists
        if [ ! -f "${KEY_NAME}.pem" ]; then
            print_error "Key exists in AWS but not locally. Please delete from AWS Console first."
            print_info "Run: aws ec2 delete-key-pair --key-name ${KEY_NAME}"
            exit 1
        fi
        print_info "Using existing local key file"
    else
        print_info "Creating new key pair: ${KEY_NAME}"
        
        # Create key pair and save to file
        aws ec2 create-key-pair \
            --key-name "${KEY_NAME}" \
            --query 'KeyMaterial' \
            --output text \
            --region ${REGION} > "${KEY_NAME}.pem"
        
        chmod 400 "${KEY_NAME}.pem"
        print_success "Key pair created and saved to ${KEY_NAME}.pem"
    fi
}

# Create security group
create_security_group() {
    print_header "Creating Security Group"
    
    # Check if security group exists
    SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
        --query 'SecurityGroups[0].GroupId' \
        --output text \
        --region ${REGION} 2>/dev/null)
    
    if [ "$SECURITY_GROUP_ID" != "None" ] && [ -n "$SECURITY_GROUP_ID" ]; then
        print_warning "Security group already exists: ${SECURITY_GROUP_NAME}"
        print_info "Security Group ID: ${SECURITY_GROUP_ID}"
    else
        print_info "Creating security group: ${SECURITY_GROUP_NAME}"
        
        SECURITY_GROUP_ID=$(aws ec2 create-security-group \
            --group-name "${SECURITY_GROUP_NAME}" \
            --description "Security group for Kubernetes kubeadm cluster" \
            --region ${REGION} \
            --query 'GroupId' \
            --output text)
        
        print_success "Security group created: ${SECURITY_GROUP_ID}"
        
        # Add tags
        aws ec2 create-tags \
            --resources ${SECURITY_GROUP_ID} \
            --tags Key=Name,Value=${SECURITY_GROUP_NAME} Key=Project,Value=${PROJECT_NAME} \
            --region ${REGION}
        
        print_info "Configuring security group rules..."
        
        # SSH access
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 22 \
            --cidr 0.0.0.0/0 \
            --region ${REGION} > /dev/null
        print_info "  ✓ SSH (22)"
        
        # Kubernetes API server
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 6443 \
            --cidr 0.0.0.0/0 \
            --region ${REGION} > /dev/null
        print_info "  ✓ Kubernetes API (6443)"
        
        # etcd server client API
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 2379-2380 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ etcd (2379-2380)"
        
        # Kubelet API
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 10250 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ Kubelet API (10250)"
        
        # kube-scheduler
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 10259 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ kube-scheduler (10259)"
        
        # kube-controller-manager
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 10257 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ kube-controller-manager (10257)"
        
        # NodePort Services
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 30000-32767 \
            --cidr 0.0.0.0/0 \
            --region ${REGION} > /dev/null
        print_info "  ✓ NodePort Services (30000-32767)"
        
        # Flannel VXLAN (if using Flannel CNI)
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol udp \
            --port 8472 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ Flannel VXLAN (8472/UDP)"
        
        # Weave Net (if using Weave CNI)
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 6783 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ Weave Net TCP (6783)"
        
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol udp \
            --port 6783-6784 \
            --source-group ${SECURITY_GROUP_ID} \
            --region ${REGION} > /dev/null
        print_info "  ✓ Weave Net UDP (6783-6784)"
        
        # HTTP/HTTPS for application access
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 80 \
            --cidr 0.0.0.0/0 \
            --region ${REGION} > /dev/null
        print_info "  ✓ HTTP (80)"
        
        aws ec2 authorize-security-group-ingress \
            --group-id ${SECURITY_GROUP_ID} \
            --protocol tcp \
            --port 443 \
            --cidr 0.0.0.0/0 \
            --region ${REGION} > /dev/null
        print_info "  ✓ HTTPS (443)"
        
        print_success "All security rules configured"
    fi
}

# Create IAM role for ECR access
create_iam_role() {
    print_header "Creating IAM Role for ECR Access"
    
    # Check if role exists
    if aws iam get-role --role-name "${IAM_ROLE_NAME}" &> /dev/null; then
        print_warning "IAM role already exists: ${IAM_ROLE_NAME}"
    else
        print_info "Creating IAM role: ${IAM_ROLE_NAME}"
        
        # Create trust policy for EC2
        cat > /tmp/ec2-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
        
        # Create the IAM role
        aws iam create-role \
            --role-name "${IAM_ROLE_NAME}" \
            --assume-role-policy-document file:///tmp/ec2-trust-policy.json \
            --description "Role for K8s nodes to access ECR" \
            > /dev/null
        
        print_success "IAM role created"
        
        # Create ECR access policy
        cat > /tmp/ecr-access-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:PutImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload"
      ],
      "Resource": "*"
    }
  ]
}
EOF
        
        # Attach ECR policy
        print_info "Attaching ECR access policy..."
        aws iam put-role-policy \
            --role-name "${IAM_ROLE_NAME}" \
            --policy-name ECRAccessPolicy \
            --policy-document file:///tmp/ecr-access-policy.json
        
        print_success "ECR access policy attached"
        
        # Wait for role to propagate
        print_info "Waiting for IAM role to propagate (15 seconds)..."
        sleep 15
    fi
    
    # Create instance profile if it doesn't exist
    if aws iam get-instance-profile --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" &> /dev/null; then
        print_warning "Instance profile already exists: ${IAM_INSTANCE_PROFILE_NAME}"
    else
        print_info "Creating instance profile: ${IAM_INSTANCE_PROFILE_NAME}"
        
        aws iam create-instance-profile \
            --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
            > /dev/null
        
        # Add role to instance profile
        aws iam add-role-to-instance-profile \
            --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
            --role-name "${IAM_ROLE_NAME}"
        
        print_success "Instance profile created and role attached"
        
        # Wait for instance profile to propagate - INCREASED WAIT TIME
        print_info "Waiting for instance profile to propagate (20 seconds)..."
        sleep 20
        
        # Verify instance profile is accessible - NEW VERIFICATION LOOP
        print_info "Verifying instance profile is ready..."
        for i in {1..6}; do
            if aws iam get-instance-profile --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" &> /dev/null; then
                # Double-check that the role is attached
                ATTACHED_ROLE=$(aws iam get-instance-profile \
                    --instance-profile-name "${IAM_INSTANCE_PROFILE_NAME}" \
                    --query 'InstanceProfile.Roles[0].RoleName' \
                    --output text 2>/dev/null)
                
                if [ "$ATTACHED_ROLE" = "${IAM_ROLE_NAME}" ]; then
                    print_success "Instance profile verified and ready"
                    break
                fi
            fi
            
            if [ $i -eq 6 ]; then
                print_error "Instance profile not ready after 50 seconds"
                print_info "This is unusual. You may need to wait and re-run the script."
                exit 1
            fi
            
            print_info "Still waiting... (attempt $i/6)"
            sleep 5
        done
    fi
}

# Create EC2 instances
create_ec2_instances() {
    print_header "Creating EC2 Instances"
    
    # Create user data script for basic setup
    cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
# Basic setup - hostname will be set by individual instances
hostnamectl set-hostname HOSTNAME_PLACEHOLDER

# Update /etc/hosts
echo "127.0.0.1 $(hostname)" >> /etc/hosts

# Update system
apt-get update -y
apt-get upgrade -y

# Install essential packages
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    software-properties-common \
    git \
    wget \
    vim \
    net-tools \
    unzip

# Disable swap (required for Kubernetes)
swapoff -a
sed -i '/swap/d' /etc/fstab

# Enable kernel modules
cat >> /etc/modules-load.d/k8s.conf << EOFF
overlay
br_netfilter
EOFF

modprobe overlay
modprobe br_netfilter

# Configure sysctl for Kubernetes
cat >> /etc/sysctl.d/k8s.conf << EOFF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOFF

sysctl --system

echo "Instance setup complete!" > /var/log/user-data.log
EOF
    
    # Check if master instance exists
    MASTER_INSTANCE_ID=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=${PROJECT_NAME}-master" \
                  "Name=instance-state-name,Values=running,stopped,stopping,pending" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text \
        --region ${REGION} 2>/dev/null)
    
    if [ "$MASTER_INSTANCE_ID" != "None" ] && [ -n "$MASTER_INSTANCE_ID" ]; then
        print_warning "Master instance already exists: ${MASTER_INSTANCE_ID}"
        
        # Get master IP
        MASTER_PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids ${MASTER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text \
            --region ${REGION})
        
        MASTER_PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids ${MASTER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text \
            --region ${REGION})
        
        print_info "Master Public IP: ${MASTER_PUBLIC_IP}"
        print_info "Master Private IP: ${MASTER_PRIVATE_IP}"
    else
        print_info "Creating master instance..."
        
        # Prepare master user data
        sed 's/HOSTNAME_PLACEHOLDER/k8s-master/' /tmp/user-data.sh > /tmp/master-user-data.sh
        
        # FIXED: Added quotes around IAM instance profile parameter
        MASTER_INSTANCE_ID=$(aws ec2 run-instances \
            --image-id ${AMI_ID} \
            --instance-type ${INSTANCE_TYPE} \
            --key-name ${KEY_NAME} \
            --security-group-ids ${SECURITY_GROUP_ID} \
            --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE_NAME}" \
            --user-data file:///tmp/master-user-data.sh \
            --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PROJECT_NAME}-master},{Key=Project,Value=${PROJECT_NAME}},{Key=Role,Value=master}]" \
            --region ${REGION} \
            --query 'Instances[0].InstanceId' \
            --output text)
        
        print_success "Master instance created: ${MASTER_INSTANCE_ID}"
        
        # Wait for instance to be running
        print_info "Waiting for master instance to be running..."
        aws ec2 wait instance-running --instance-ids ${MASTER_INSTANCE_ID} --region ${REGION}
        
        # Get IPs
        MASTER_PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids ${MASTER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text \
            --region ${REGION})
        
        MASTER_PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids ${MASTER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text \
            --region ${REGION})
        
        print_success "Master instance running"
        print_info "Master Public IP: ${MASTER_PUBLIC_IP}"
        print_info "Master Private IP: ${MASTER_PRIVATE_IP}"
    fi
    
    # Create worker instances
    for i in 1 2; do
        WORKER_NAME="${PROJECT_NAME}-worker${i}"
        
        # Check if worker instance exists
        WORKER_INSTANCE_ID=$(aws ec2 describe-instances \
            --filters "Name=tag:Name,Values=${WORKER_NAME}" \
                      "Name=instance-state-name,Values=running,stopped,stopping,pending" \
            --query 'Reservations[0].Instances[0].InstanceId' \
            --output text \
            --region ${REGION} 2>/dev/null)
        
        if [ "$WORKER_INSTANCE_ID" != "None" ] && [ -n "$WORKER_INSTANCE_ID" ]; then
            print_warning "Worker${i} instance already exists: ${WORKER_INSTANCE_ID}"
            
            # Get worker IP
            WORKER_PUBLIC_IP=$(aws ec2 describe-instances \
                --instance-ids ${WORKER_INSTANCE_ID} \
                --query 'Reservations[0].Instances[0].PublicIpAddress' \
                --output text \
                --region ${REGION})
            
            WORKER_PRIVATE_IP=$(aws ec2 describe-instances \
                --instance-ids ${WORKER_INSTANCE_ID} \
                --query 'Reservations[0].Instances[0].PrivateIpAddress' \
                --output text \
                --region ${REGION})
            
            print_info "Worker${i} Public IP: ${WORKER_PUBLIC_IP}"
            print_info "Worker${i} Private IP: ${WORKER_PRIVATE_IP}"
            
            # Store worker IPs
            eval "WORKER${i}_INSTANCE_ID=${WORKER_INSTANCE_ID}"
            eval "WORKER${i}_PUBLIC_IP=${WORKER_PUBLIC_IP}"
            eval "WORKER${i}_PRIVATE_IP=${WORKER_PRIVATE_IP}"
        else
            print_info "Creating worker${i} instance..."
            
            # Prepare worker user data
            sed "s/HOSTNAME_PLACEHOLDER/k8s-worker${i}/" /tmp/user-data.sh > /tmp/worker${i}-user-data.sh
            
            # FIXED: Added quotes around IAM instance profile parameter
            WORKER_INSTANCE_ID=$(aws ec2 run-instances \
                --image-id ${AMI_ID} \
                --instance-type ${INSTANCE_TYPE} \
                --key-name ${KEY_NAME} \
                --security-group-ids ${SECURITY_GROUP_ID} \
                --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE_NAME}" \
                --user-data file:///tmp/worker${i}-user-data.sh \
                --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${WORKER_NAME}},{Key=Project,Value=${PROJECT_NAME}},{Key=Role,Value=worker}]" \
                --region ${REGION} \
                --query 'Instances[0].InstanceId' \
                --output text)
            
            print_success "Worker${i} instance created: ${WORKER_INSTANCE_ID}"
            
            # Store worker ID
            eval "WORKER${i}_INSTANCE_ID=${WORKER_INSTANCE_ID}"
        fi
    done
    
    # Wait for all worker instances to be running
    print_info "Waiting for all worker instances to be running..."
    aws ec2 wait instance-running --instance-ids ${WORKER1_INSTANCE_ID} ${WORKER2_INSTANCE_ID} --region ${REGION}
    
    # Get worker IPs if not already retrieved
    for i in 1 2; do
        WORKER_INSTANCE_ID_VAR="WORKER${i}_INSTANCE_ID"
        WORKER_INSTANCE_ID=${!WORKER_INSTANCE_ID_VAR}
        
        WORKER_PUBLIC_IP=$(aws ec2 describe-instances \
            --instance-ids ${WORKER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PublicIpAddress' \
            --output text \
            --region ${REGION})
        
        WORKER_PRIVATE_IP=$(aws ec2 describe-instances \
            --instance-ids ${WORKER_INSTANCE_ID} \
            --query 'Reservations[0].Instances[0].PrivateIpAddress' \
            --output text \
            --region ${REGION})
        
        eval "WORKER${i}_PUBLIC_IP=${WORKER_PUBLIC_IP}"
        eval "WORKER${i}_PRIVATE_IP=${WORKER_PRIVATE_IP}"
        
        print_success "Worker${i} instance running"
        print_info "Worker${i} Public IP: ${WORKER_PUBLIC_IP}"
        print_info "Worker${i} Private IP: ${WORKER_PRIVATE_IP}"
    done
    
    print_info "Waiting for instances to initialize (30 seconds)..."
    sleep 30
}

# Update deployment-info.txt
update_deployment_info() {
    print_header "Updating deployment-info.txt"
    
    cat > deployment-info.txt << EOF
# Kubernetes kubeadm Cluster - Deployment Information
# Generated: $(date)
# IMPORTANT: Source this file to load variables: source deployment-info.txt

export PROJECT_NAME="${PROJECT_NAME}"
export REGION="${REGION}"
export INSTANCE_TYPE="${INSTANCE_TYPE}"
export AMI_ID="${AMI_ID}"

# SSH Key
export KEY_NAME="${KEY_NAME}"
export KEY_FILE="${KEY_NAME}.pem"

# Security Group
export SECURITY_GROUP_ID="${SECURITY_GROUP_ID}"
export SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME}"

# IAM Role
export IAM_ROLE_NAME="${IAM_ROLE_NAME}"
export IAM_INSTANCE_PROFILE_NAME="${IAM_INSTANCE_PROFILE_NAME}"

# Master Node
export MASTER_INSTANCE_ID="${MASTER_INSTANCE_ID}"
export MASTER_PUBLIC_IP="${MASTER_PUBLIC_IP}"
export MASTER_PRIVATE_IP="${MASTER_PRIVATE_IP}"

# Worker Node 1
export WORKER1_INSTANCE_ID="${WORKER1_INSTANCE_ID}"
export WORKER1_PUBLIC_IP="${WORKER1_PUBLIC_IP}"
export WORKER1_PRIVATE_IP="${WORKER1_PRIVATE_IP}"

# Worker Node 2
export WORKER2_INSTANCE_ID="${WORKER2_INSTANCE_ID}"
export WORKER2_PUBLIC_IP="${WORKER2_PUBLIC_IP}"
export WORKER2_PRIVATE_IP="${WORKER2_PRIVATE_IP}"

# SSH Connection Commands
# ssh -i ${KEY_NAME}.pem ubuntu@\$MASTER_PUBLIC_IP
# ssh -i ${KEY_NAME}.pem ubuntu@\$WORKER1_PUBLIC_IP
# ssh -i ${KEY_NAME}.pem ubuntu@\$WORKER2_PUBLIC_IP
EOF
    
    print_success "deployment-info.txt updated"
    print_info "Load variables with: source deployment-info.txt"
}

# Print summary
print_summary() {
    print_header "Infrastructure Setup Complete!"
    
    echo -e "${GREEN}✓ SSH Key Pair:${NC} ${KEY_NAME}"
    echo -e "${GREEN}✓ Security Group:${NC} ${SECURITY_GROUP_ID}"
    echo -e "${GREEN}✓ IAM Role:${NC} ${IAM_ROLE_NAME}"
    echo -e "${GREEN}✓ Instance Profile:${NC} ${IAM_INSTANCE_PROFILE_NAME}"
    
    echo -e "\n${BLUE}EC2 Instances:${NC}"
    echo -e "  ${CYAN}Master:${NC}"
    echo -e "    - Instance ID: ${MASTER_INSTANCE_ID}"
    echo -e "    - Public IP:   ${MASTER_PUBLIC_IP}"
    echo -e "    - Private IP:  ${MASTER_PRIVATE_IP}"
    echo -e "    - Connect:     ssh -i ${KEY_NAME}.pem ubuntu@${MASTER_PUBLIC_IP}"
    
    echo -e "\n  ${CYAN}Worker 1:${NC}"
    echo -e "    - Instance ID: ${WORKER1_INSTANCE_ID}"
    echo -e "    - Public IP:   ${WORKER1_PUBLIC_IP}"
    echo -e "    - Private IP:  ${WORKER1_PRIVATE_IP}"
    echo -e "    - Connect:     ssh -i ${KEY_NAME}.pem ubuntu@${WORKER1_PUBLIC_IP}"
    
    echo -e "\n  ${CYAN}Worker 2:${NC}"
    echo -e "    - Instance ID: ${WORKER2_INSTANCE_ID}"
    echo -e "    - Public IP:   ${WORKER2_PUBLIC_IP}"
    echo -e "    - Private IP:  ${WORKER2_PRIVATE_IP}"
    echo -e "    - Connect:     ssh -i ${KEY_NAME}.pem ubuntu@${WORKER2_PUBLIC_IP}"
    
    echo -e "\n${YELLOW}⚠ Important Notes:${NC}"
    echo -e "  1. Instances are initializing. Wait 2-3 minutes before SSH connection"
    echo -e "  2. Load deployment variables: ${CYAN}source deployment-info.txt${NC}"
    echo -e "  3. Test SSH connection before proceeding to next steps"
    echo -e "  4. All instances have ECR access via IAM role"
    
    echo -e "\n${BLUE}Next Steps:${NC}"
    echo -e "  1. Load variables: ${YELLOW}source deployment-info.txt${NC}"
    echo -e "  2. Test SSH: ${YELLOW}ssh -i ${KEY_NAME}.pem ubuntu@\$MASTER_PUBLIC_IP${NC}"
    echo -e "  3. Proceed to Chat 2: Install Kubernetes components"
}

# Main execution
main() {
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Kubernetes kubeadm Cluster Infrastructure Setup    ║"
    echo "║   Phase 1: AWS Resources Creation                    ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    
    check_prerequisites
    get_ubuntu_ami
    create_ssh_key
    create_security_group
    create_iam_role
    create_ec2_instances
    update_deployment_info
    print_summary
    
    echo -e "\n${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       Infrastructure Setup Completed Successfully!    ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
}

# Run main function
main
