---
applyTo: "kubernetes/apps/**/app/externalsecret.yaml"
---

# Instructions for Secret Management

## Overview
This repository uses External Secrets Operator (ESO) for managing secrets from external providers like 1Password. Never commit plaintext secrets to the repository.

## External Secrets Operator

### ExternalSecret Resources
When working with `externalsecret.yaml` files:
- Use `external-secrets.io/v1beta1` API version
- Reference the appropriate SecretStore (e.g., onepassword-connect)
- Use target creation policy `Owner` for proper lifecycle management
- Use template data with references to external values
- Structure paths consistently (e.g., `op://vault/item/field` for 1Password)

### Schema Validation
Include the schema header:
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/external-secrets.io/externalsecret_v1beta1.json
```

### Best Practices
- Use YAML anchors for repeated values like credentials
- Store tokens securely as bootstrap secrets
- Reference secrets securely in environment variables
- Test secret retrieval before committing

### Example
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/external-secrets.io/externalsecret_v1beta1.json
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secrets
spec:
  secretStoreRef:
    name: onepassword-connect
    kind: SecretStore
  target:
    name: my-app-secrets
    creationPolicy: Owner
  data:
  - secretKey: api-key
    remoteRef:
      key: op://vault/my-app/api-key
```

## General Secret Management
- Encrypt secrets using SOPS with AGE when necessary
- Name encrypted files with `.sops.yaml` suffix
- Use ESO for external secret providers
- Follow RBAC principles for secret access
