#!/bin/bash
################################################################################
# Display Application URLs
# Shows all important URLs and credentials for the project
################################################################################

# Load deployment info
if [ -f deployment-info.txt ]; then
    source deployment-info.txt
else
    echo "❌ deployment-info.txt not found!"
    exit 1
fi

echo ""
echo "════════════════════════════════════════════════════════"
echo "  HADDAR'S RETAIL STORE - APPLICATION URLS"
echo "════════════════════════════════════════════════════════"
echo ""
echo "🛒 Retail Store App: http://${MASTER_PUBLIC_IP}:30080"
echo ""
echo "🚀 ArgoCD Dashboard: https://${MASTER_PUBLIC_IP}:30090"
echo "   Username: admin"
echo "   Password: ${ARGOCD_ADMIN_PASSWORD:-<not set yet - run 06-argocd-setup.sh>}"
echo ""
echo "════════════════════════════════════════════════════════"
echo ""
echo "📊 Infrastructure Details:"
echo "   Master Node:    ${MASTER_PUBLIC_IP}"
echo "   Worker 1:       ${WORKER1_PUBLIC_IP}"
echo "   Worker 2:       ${WORKER2_PUBLIC_IP}"
echo "   ECR Registry:   ${ECR_REGISTRY}"
echo "   DynamoDB Table: ${DYNAMODB_TABLE_NAME}"
echo ""
echo "════════════════════════════════════════════════════════"
echo ""