#!/bin/bash

################################################################################
# Startup Script - Start EC2 Instances and Update IPs
# Run this every time you start working on the project after EC2s were stopped
#
# Usage: ./startup.sh && source restore-vars.sh
################################################################################

set -e

# Script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOYMENT_INFO="${SCRIPT_DIR}/deployment-info.txt"

# Check if deployment info exists
if [ ! -f "$DEPLOYMENT_INFO" ]; then
    echo "❌ deployment-info.txt not found!"
    echo "Please run ./02-terraform-apply.sh first"
    exit 1
fi

# Source current deployment info
source "$DEPLOYMENT_INFO"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

echo -e "${BLUE}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Startup Script - Starting EC2 Instances            ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}\n"

# Check AWS CLI
if ! command -v aws &> /dev/null; then
    echo "❌ AWS CLI not found"
    exit 1
fi

# Verify AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    echo "❌ AWS credentials not configured"
    exit 1
fi

print_header "Starting EC2 Instances"

# Get all instance IDs
INSTANCE_IDS="${MASTER_INSTANCE_ID} ${WORKER1_INSTANCE_ID} ${WORKER2_INSTANCE_ID}"

print_info "Checking instance states..."

# Check current state
for INSTANCE_ID in $INSTANCE_IDS; do
    STATE=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text 2>/dev/null || echo "not-found")
    
    if [ "$STATE" = "stopped" ]; then
        print_info "Starting instance: $INSTANCE_ID"
        aws ec2 start-instances --instance-ids "$INSTANCE_ID" > /dev/null
    elif [ "$STATE" = "running" ]; then
        print_success "Instance already running: $INSTANCE_ID"
    else
        print_info "Instance state: $STATE ($INSTANCE_ID)"
    fi
done

# Wait for all instances to be running
print_info "Waiting for instances to start..."
aws ec2 wait instance-running --instance-ids $INSTANCE_IDS

# Give services time to start
print_info "Waiting for services to initialize (60 seconds)..."
sleep 60

print_success "All instances are running"

# Get updated IPs
print_header "Updating IP Addresses"

# Update master IP
NEW_MASTER_IP=$(aws ec2 describe-instances \
    --instance-ids "$MASTER_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

NEW_WORKER1_IP=$(aws ec2 describe-instances \
    --instance-ids "$WORKER1_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

NEW_WORKER2_IP=$(aws ec2 describe-instances \
    --instance-ids "$WORKER2_INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

# Update deployment-info.txt with new IPs
sed -i "s|^export MASTER_PUBLIC_IP=.*|export MASTER_PUBLIC_IP=\"${NEW_MASTER_IP}\"|" "$DEPLOYMENT_INFO"
sed -i "s|^export WORKER1_PUBLIC_IP=.*|export WORKER1_PUBLIC_IP=\"${NEW_WORKER1_IP}\"|" "$DEPLOYMENT_INFO"
sed -i "s|^export WORKER2_PUBLIC_IP=.*|export WORKER2_PUBLIC_IP=\"${NEW_WORKER2_IP}\"|" "$DEPLOYMENT_INFO"

print_success "IP addresses updated in deployment-info.txt"

# Summary
print_header "Startup Complete!"

echo -e "${GREEN}✅ All EC2 instances are running${NC}"
echo ""
echo -e "${BLUE}Updated IP Addresses:${NC}"
echo -e "  Master:   ${CYAN}${NEW_MASTER_IP}${NC}"
echo -e "  Worker1:  ${CYAN}${NEW_WORKER1_IP}${NC}"
echo -e "  Worker2:  ${CYAN}${NEW_WORKER2_IP}${NC}"
echo ""
echo -e "${YELLOW}⚠️  Important:${NC}"
echo "  Load updated variables with: ${CYAN}source restore-vars.sh${NC}"
echo ""
echo -e "${BLUE}Next Steps:${NC}"
echo "  1. source restore-vars.sh"
echo "  2. ./Display-App-URLs.sh"
echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         EC2 Instances Started Successfully! 🎉        ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}\n"
