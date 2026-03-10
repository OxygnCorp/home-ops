---
applyTo: "**/*.yaml"
---

# YAML Schema Validation Guidelines

This file provides authoritative schema URLs and best practices for YAML schema validation in this repository. Always follow these guidelines when working with YAML manifests.

## Schema Reference Best Practice

- Always use the latest authoritative schema URLs for each manifest type.
- Place schema references as a comment before the document separator (---) at the top of each YAML file for best IDE compatibility.
- Review and update schema URLs regularly as upstream projects change.

## Schema URLs by Resource Type

### Kubernetes Core Resources
- **Namespace**: `https://k8s-schemas.oxygn.dev/v1/namespace.json`
- **ConfigMap**: `https://k8s-schemas.oxygn.dev/v1/configmap.json`
- **Secret**: `https://k8s-schemas.oxygn.dev/v1/secret.json`
- **Service**: `https://k8s-schemas.oxygn.dev/v1/service.json`
- **Deployment**: `https://k8s-schemas.oxygn.dev/apps/v1/deployment.json`
- **PersistentVolumeClaim**: `https://k8s-schemas.oxygn.dev/v1/persistentvolumeclaim.json`

### Flux Resources
- **Kustomization**: `https://k8s-schemas.oxygn.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json`
- **HelmRelease**: `https://k8s-schemas.oxygn.dev/helm.toolkit.fluxcd.io/helmrelease_v2beta1.json`
- **GitRepository**: `https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/gitrepository_v1.json`
- **HelmRepository**: `https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/helmrepository_v1.json`
- **OCIRepository**: `https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/ocirepository_v1.json`

### Kustomize
- **Kustomization**: `https://k8s-schemas.oxygn.dev/kustomize.config.k8s.io/kustomization_v1beta1.json`

### External Secrets Operator
- **ExternalSecret**: `https://k8s-schemas.oxygn.dev/external-secrets.io/externalsecret_v1beta1.json`
- **SecretStore**: `https://k8s-schemas.oxygn.dev/external-secrets.io/secretstore_v1beta1.json`

### Other Tools
- **CertManager Certificate**: `https://k8s-schemas.oxygn.dev/cert-manager.io/certificate_v1.json`
- **Ingress**: `https://k8s-schemas.oxygn.dev/networking.k8s.io/v1/ingress.json`

## Usage Example

```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/helm.toolkit.fluxcd.io/helmrelease_v2beta1.json
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: example
spec:
  # ... rest of the manifest
```

## Validation Tools

Use yaml-language-server in your IDE for real-time validation. Ensure the schema URLs are up-to-date by checking the oxygn.dev schemas repository.
