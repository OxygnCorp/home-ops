---
applyTo: "flux/**/*.yaml"
---

# Instructions for Flux Configuration

## Overview
Flux manages continuous deployment and reconciliation of Kubernetes resources. Configuration files are located in the `flux/` directory.

## Key Components

### Flux Kustomizations
- Use `kustomize.toolkit.fluxcd.io/v1` for Kustomization resources
- Set reconciliation intervals appropriately (10m for cluster-level, 15m for apps)
- Always configure `prune: true` for garbage collection
- Include proper dependencies with `dependsOn`

### Source Controllers
- **GitRepository**: For Git-based sources
- **HelmRepository**: For Helm chart repositories
- **OCIRepository**: For OCI-based charts
- Set appropriate intervals (15m for sources)

### HelmReleases
- Use `helm.toolkit.fluxcd.io/v2beta1` API version
- Configure remediation with retries
- Pin chart versions explicitly
- Use proper health checks

### Schema Validation
Include appropriate schema headers for each resource type (see yaml-schemas.instructions.md).

### Best Practices
- Group related resources with Kustomizations
- Use source controllers to track external dependencies
- Implement health checks for automatic rollback
- Follow progressive delivery patterns
- Use SOPS for secret decryption

### Example Cluster Kustomization
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./kubernetes/apps
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
```
