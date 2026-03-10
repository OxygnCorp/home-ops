---
applyTo: "kubernetes/apps/network/**/externaldns*.yaml"
---

# Instructions for ExternalDNS Configuration

## Overview
ExternalDNS manages DNS records for Kubernetes services and ingresses. This repository uses separate deployments for external (Cloudflare) and internal (Bind) DNS.

## Configuration Guidelines

### External DNS (Cloudflare)
When working with external DNS configurations:
- Use `external-dns.alpha.kubernetes.io/target: external.domain.com` annotation
- Configure `--cloudflare-proxied` when appropriate
- Use proper Cloudflare API tokens via ESO

### Internal DNS (Bind)
When working with internal DNS:
- Use `external-dns.alpha.kubernetes.io/target: internal.domain.com` annotation
- Configure TSIG authentication for secure updates
- Use appropriate zone configurations

### Direct Hostname Assignment
- Use `external-dns.alpha.kubernetes.io/hostname` for specific hostnames
- Use YAML anchors for consistent hostname patterns

### Schema Validation
For ExternalDNS-related manifests, use appropriate Kubernetes schemas (e.g., Deployment, ConfigMap).

### Best Practices
- Separate external and internal DNS deployments
- Use ESO for API credentials
- Test DNS propagation before committing
- Follow domain naming conventions

### Example Annotations
```yaml
metadata:
  annotations:
    external-dns.alpha.kubernetes.io/hostname: my-app.external.domain.com
    external-dns.alpha.kubernetes.io/target: external.domain.com
```
