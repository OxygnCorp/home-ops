---
applyTo: "kubernetes/apps/**/app/ocirepository.yaml"
---

# Instructions for OCIRepository files

## Overview
OCIRepository files define sources for pulling Helm charts from OCI registries like GHCR.

## Schema Validation
Always include the YAML schema header:
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
```

## Structure and Best Practices
- **apiVersion**: `source.toolkit.fluxcd.io/v1`
- **kind**: `OCIRepository`
- **metadata**: `name` matching the app
- **spec**:
  - `interval`: `15m`
  - `url`: OCI URL, e.g., `oci://ghcr.io/bjw-s-labs/helm/app-template`
  - `ref`: Specify `tag` for versioning
  - `layerSelector`: Include for Helm charts with `mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip` and `operation: copy`

## Example
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: my-app
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: latest
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```
