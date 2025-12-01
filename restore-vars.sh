#!/bin/bash

################################################################################
# Restore Environment Variables
# Sources deployment-info.txt to load all environment variables
#
# Usage: source restore-vars.sh
# (Must use 'source' or '.' to export variables to current shell)
################################################################################

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
DEPLOYMENT_INFO="${SCRIPT_DIR}/deployment-info.txt"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

if [ ! -f "$DEPLOYMENT_INFO" ]; then
    echo -e "${RED}❌ deployment-info.txt not found!${NC}"
    echo -e "${CYAN}Run ./02-terraform-apply.sh first to create it.${NC}"
    return 1 2>/dev/null || exit 1
fi

# Source the deployment info
source "$DEPLOYMENT_INFO"

echo -e "${GREEN}✅ Environment variables loaded${NC}"
echo ""
echo -e "${CYAN}Key Variables:${NC}"
echo "  REGION:              $REGION"
echo "  MASTER_PUBLIC_IP:    $MASTER_PUBLIC_IP"
echo "  WORKER1_PUBLIC_IP:   $WORKER1_PUBLIC_IP"
echo "  WORKER2_PUBLIC_IP:   $WORKER2_PUBLIC_IP"
echo "  ECR_REGISTRY:        $ECR_REGISTRY"
echo "  DYNAMODB_TABLE_NAME: $DYNAMODB_TABLE_NAME"
echo ""
echo -e "${GREEN}All variables available in current shell ✓${NC}"
