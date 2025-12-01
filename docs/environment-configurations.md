# Environment-Specific Configurations

## Overview

This document describes how the Retail Store application supports multiple deployment environments using GitOps principles.

## Current Implementation (Learning/Development)

For this class project, we use a **single environment** deployed to our kubeadm cluster:
```
gitops-retail-store-app/
└── apps/
    ├── ui/
    ├── catalog/
    ├── cart/
    ├── orders/
    ├── checkout/
    └── dependencies/
```

**Key Configuration:**
- Namespace: `retail-store`
- Replicas: 1 per service
- Image Tags: Commit SHA (updated by CI/CD)
- Auto-sync: Enabled
- Authentication: ECR Credential Helper (IAM role)

---

## Production-Ready Structure (Multi-Environment)

In a real-world scenario, you would implement environment-specific configurations:
```
gitops-retail-store-app/
├── base/                          # Shared configurations
│   ├── ui/
│   ├── catalog/
│   ├── cart/
│   ├── orders/
│   └── checkout/
│
├── overlays/                      # Environment-specific
│   ├── dev/
│   │   └── values-*.yaml
│   ├── staging/
│   │   └── values-*.yaml
│   └── prod/
│       └── values-*.yaml
│
└── argocd/
    └── applications/
        ├── dev/
        ├── staging/
        └── prod/
```

---

## Environment Differences

| Setting | Dev | Staging | Production |
|---------|-----|---------|------------|
| Replicas | 1 | 2 | 3+ |
| Resources | Low | Medium | High |
| Image Tag | `latest` | RC tag | Semantic version |
| Auto-sync | ✅ Yes | ✅ Yes | ⚠️ Manual approve |
| Database | In-cluster | In-cluster/RDS | AWS RDS |

---

## ArgoCD per Environment

Each environment would have separate ArgoCD Applications:
```yaml
# Dev
spec:
  destination:
    namespace: retail-store-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

# Production
spec:
  destination:
    namespace: retail-store-prod
  syncPolicy:
    automated:
      prune: false          # Don't auto-delete!
      selfHeal: true
```

---

## Promotion Workflow
```
┌─────────┐     ┌─────────┐     ┌──────────┐
│   DEV   │────▶│ STAGING │────▶│   PROD   │
└─────────┘     └─────────┘     └──────────┘
  latest        v1.2.0-rc1       v1.2.0
```

**Steps:**
1. Push to `main` → auto-deploy to dev
2. Create RC tag → auto-deploy to staging
3. QA approval → create release tag → manual deploy to prod

---

## Current Project Implementation

| Aspect | Our Implementation |
|--------|-------------------|
| Environments | Single (dev/learning) |
| Namespace | `retail-store` |
| Image Tags | Commit SHA |
| Auto-sync | Enabled |
| Replicas | 1 per service |
| Authentication | ECR Credential Helper (no secrets) |

This demonstrates GitOps principles while keeping the project manageable for learning purposes.

---

## Future Enhancements

To make this production-ready:

1. **Add environment overlays** - Separate dev/staging/prod configs
2. **Implement promotion workflow** - PR-based promotions
3. **Add approval gates** - Manual approval for production
4. **Configure RBAC** - Limit deployment permissions
5. **Implement secrets management** - Sealed Secrets or External Secrets
6. **Add monitoring per environment** - Separate dashboards