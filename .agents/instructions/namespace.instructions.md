---
applyTo: "kubernetes/apps/**/app/namespace.yaml"
---

# Instructions for Namespace files

## Overview
Namespace files define the Kubernetes namespace for each application.

## Schema Validation
Include the schema header:
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/v1/namespace.json
```

## Structure and Best Practices
- **apiVersion**: `v1`
- **kind**: `Namespace`
- **metadata**: `name` matching the app namespace

## Example
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/v1/namespace.json
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```
