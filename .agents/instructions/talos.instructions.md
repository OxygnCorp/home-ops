---
applyTo: "talos/**/*.yaml"
---

# Instructions for Talos OS Configuration

## Overview
Talos OS configurations manage the cluster nodes. Configurations are templated and version-controlled.

## Configuration Guidelines

### Machine Configuration
- Use `talconfig.yaml` or similar for defining Talos machine configurations
- Pin Talos and Kubernetes versions using Renovate annotations
- Configure node-specific settings under the `nodes` section
- Use YAML anchors for repeated values like VLAN configurations

### Networking
- Configure network interfaces with proper bonds and VLANs
- Use consistent IP addressing schemes
- Configure DNS and NTP settings

### Schema Validation
Talos configurations may not have standard Kubernetes schemas, but include comments for clarity.

### Best Practices
- Use `talosctl` for cluster management operations
- Version control all configurations
- Test configurations in development before applying
- Document node-specific customizations
- Use templates for consistent configurations across nodes

### Example Node Configuration
```yaml
# Example Talos node configuration
machine:
  type: controlplane
  token: ${TALOS_TOKEN}
  ca:
    crt: ${TALOS_CA_CRT}
    key: ${TALOS_CA_KEY}
cluster:
  name: home-cluster
  controlPlane:
    endpoint: https://192.168.1.10:6443
  network:
    dnsDomain: cluster.local
    podSubnets: ["10.244.0.0/16"]
    serviceSubnets: ["10.96.0.0/12"]
```
