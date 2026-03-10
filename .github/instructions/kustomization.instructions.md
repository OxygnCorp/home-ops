---
applyTo: "kubernetes/apps/**/app/kustomization.yaml"
---

# Instructions for Kustomize Kustomization files

## Overview
Kustomization files in the `app/` directory combine and customize Kubernetes resources for each application.

## Schema Validation
Include the schema header:
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
```

## Structure and Best Practices
- **apiVersion**: `kustomize.config.k8s.io/v1beta1`
- **kind**: `Kustomization`
- **resources**: List all YAML files in the app directory (namespace.yaml, helmrelease.yaml, ocirepository.yaml, etc.)
- Use patches for customizations if needed

## Example
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ocirepository.yaml
```
