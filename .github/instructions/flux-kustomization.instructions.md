---
applyTo: "kubernetes/apps/**/ks.yaml"
---

# Instructions for Flux Kustomization files (ks.yaml)

## Overview
Flux Kustomization files (`ks.yaml`) are used to manage the deployment of applications via GitOps. They define how Flux reconciles the cluster state with the repository.

## Schema Validation
Always include the YAML schema header for validation:
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
```

## Structure and Best Practices
- **apiVersion**: Use `kustomize.toolkit.fluxcd.io/v1`
- **kind**: `Kustomization`
- **metadata**: Include `name` and `namespace`
- **spec**:
  - `interval`: Set to `30m` for standard reconciliation
  - `path`: Point to the `./kubernetes/apps/<category>/<app-name>/app` directory
  - `dependsOn`: List dependencies on other Kustomizations if needed
  - `components`: Reference shared components like `volsync` if applicable
  - `commonMetadata`: Add labels for consistency

## Example
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: my-app
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: my-app
  components:
    - ../../../../components/volsync
  dependsOn:
    - name: nvidia-device-plugin
      namespace: kube-system
  interval: 30m
  path: ./kubernetes/apps/<category>/my-app/app
```
