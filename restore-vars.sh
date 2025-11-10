#!/bin/bash

################################################################################
# Retail Store Kubernetes - Variable Restoration Script
# This script sources the deployment-info.txt file to restore all project
# variables to your current terminal session.
#
# Usage: source restore-vars.sh
#   (NOTE: Must use 'source' or '.' to affect current shell)
################################################################################

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOYMENT_INFO="${SCRIPT_DIR}/deployment-info.txt"

echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Restoring Project Variables...              ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
echo ""

# Check if deployment-info.txt exists
if [ ! -f "$DEPLOYMENT_INFO" ]; then
    echo -e "${RED}✗ Error: deployment-info.txt not found!${NC}"
    echo -e "${YELLOW}  Expected location: ${DEPLOYMENT_INFO}${NC}"
    echo -e "${YELLOW}  Please run the deployment script first.${NC}"
    return 1 2>/dev/null || exit 1
fi

# Source the deployment info file
source "$DEPLOYMENT_INFO"

# Verify some key variables were loaded
if [ -z "$PROJECT_NAME" ]; then
    echo -e "${RED}✗ Error: Variables not loaded properly${NC}"
    return 1 2>/dev/null || exit 1
fi

echo -e "${GREEN}✓ Variables restored successfully!${NC}"
echo ""

# Display key variables
echo -e "${BLUE}Key Variables:${NC}"
echo "  Project:        $PROJECT_NAME"
echo "  AWS Region:     $AWS_REGION"

# Show EC2 instance info if available
if [ -n "$MASTER_IP" ]; then
    echo ""
    echo -e "${BLUE}EC2 Instances:${NC}"
    echo "  Master:  $MASTER_IP (ID: ${MASTER_INSTANCE_ID:-not set})"
    if [ -n "$WORKER1_IP" ]; then
        echo "  Worker1: $WORKER1_IP (ID: ${WORKER1_INSTANCE_ID:-not set})"
    fi
    if [ -n "$WORKER2_IP" ]; then
        echo "  Worker2: $WORKER2_IP (ID: ${WORKER2_INSTANCE_ID:-not set})"
    fi
else
    echo -e "${YELLOW}  (No EC2 instances deployed yet)${NC}"
fi

# Show ECR info if available
if [ -n "$ECR_REGISTRY" ]; then
    echo ""
    echo -e "${BLUE}ECR Registry:${NC}"
    echo "  $ECR_REGISTRY"
else
    echo -e "${YELLOW}  (ECR not configured yet)${NC}"
fi

# Show cluster info if available
if [ -n "$K8S_JOIN_COMMAND" ]; then
    echo ""
    echo -e "${GREEN}✓ Kubernetes cluster configured${NC}"
else
    echo -e "${YELLOW}  (Kubernetes cluster not initialized yet)${NC}"
fi

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Variables Ready!                            ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}Tip: Use 'echo \$MASTER_IP' to check specific variables${NC}"
echo ""
