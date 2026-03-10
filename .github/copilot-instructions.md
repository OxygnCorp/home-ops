# GitHub Copilot Instructions for home-ops Repository

This repository manages a GitOps-based Kubernetes deployment using FluxCD to deploy and maintain applications on a Talos-based cluster. The repository follows structured patterns for application deployment, secret management, and infrastructure configuration.

## Modular Instruction Files

This repository maintains modular instruction files for different aspects of the GitOps workflow in `.github/instructions/`. These files serve as detailed reference documentation, while this main file contains all the critical information that GitHub Copilot needs.

**Reference instruction files:**

- [`repo-structure.instructions.md`](instructions/repo-structure.instructions.md): Repository structure and operations guide
- [`flux.instructions.md`](instructions/flux.instructions.md): Flux configuration guidelines
- [`flux-kustomization.instructions.md`](instructions/flux-kustomization.instructions.md): Flux Kustomization (ks.yaml) guidelines
- [`ocirepository.instructions.md`](instructions/ocirepository.instructions.md): OCIRepository configuration
- [`kustomization.instructions.md`](instructions/kustomization.instructions.md): Kustomize kustomization.yaml patterns
- [`namespace.instructions.md`](instructions/namespace.instructions.md): Namespace definitions
- [`helmrelease.instructions.md`](instructions/helmrelease.instructions.md): HelmRelease patterns and examples
- [`secrets.instructions.md`](instructions/secrets.instructions.md): Secret management practices
- [`externaldns.instructions.md`](instructions/externaldns.instructions.md): ExternalDNS configuration
- [`talos.instructions.md`](instructions/talos.instructions.md): Talos OS configuration best practices
- [`volsync.instructions.md`](instructions/volsync.instructions.md): VolSync integration for persistent storage
- [`yaml-schemas.instructions.md`](instructions/yaml-schemas.instructions.md): YAML Schema Validation Guidelines
- [`sorting.instructions.md`](instructions/sorting.instructions.md): YAML sorting rules

> **Note**: The guidance from these files is incorporated into the sections below. When working with specific components, refer to the relevant sections in this file.

## Instructions Reference Guide

The following sections contain file-specific guidance. When helping with code in this repository, apply these instructions based on the context:

- **For Flux Configuration Files**: Apply the Flux guidelines when working with files in `flux/`.
- **For Flux Kustomization Files**: Apply the Flux Kustomization best practices when working with `ks.yaml` files.
- **For OCIRepository Files**: Apply the OCIRepository patterns when working with `ocirepository.yaml` files.
- **For Kustomize Files**: Apply the Kustomize guidelines when working with `kustomization.yaml` files.
- **For Namespace Files**: Apply the Namespace patterns when working with `namespace.yaml` files.
- **For HelmRelease Files**: Apply the HelmRelease patterns when working with `helmrelease.yaml` files.
- **For Secret Management**: Apply the secret management practices when working with secret-related files.
- **For ExternalDNS**: Apply the ExternalDNS practices when working with DNS configuration files.
- **For Talos Configuration**: Apply the Talos management guidelines when working with files in `talos/`.
- **For VolSync**: Apply the VolSync integration practices when working with persistent storage.
- **For All YAML Files**: Apply the sorting rules from `sorting.instructions.md` and schema validation from `yaml-schemas.instructions.md`.

## Component-Specific Guidelines

### Flux Configuration
When working with files in `flux/`:
- Use appropriate API versions for Flux resources
- Set reconciliation intervals (10m for cluster, 15m for apps)
- Configure `prune: true` for garbage collection
- Use SOPS for secret decryption

### Secret Management
When working with secrets:
- Never commit plaintext secrets
- Use External Secrets Operator for external providers
- Encrypt with SOPS/AGE when needed
- Name encrypted files with `.sops.yaml` suffix

### ExternalDNS
When working with ExternalDNS:
- Use separate deployments for external and internal DNS
- Configure proper annotations for DNS targets
- Use ESO for API credentials
- Test DNS propagation

### Talos Configuration
When working with files in `talos/`:
- Use `talconfig.yaml` with proper schema references
- Pin Talos and Kubernetes versions
- Configure node-specific settings
- Use YAML anchors for repeated values

### VolSync
When working with VolSync:
- Configure backup schedules appropriately
- Set retention policies
- Use proper storage classes
- Test restore procedures

## Repository Overview

This repository manages a Kubernetes cluster using GitOps with Flux. Key components include:
- **Flux**: For continuous deployment
- **Kustomize**: For resource customization
- **Helm**: For application packaging
- **External Secrets Operator**: For secret management
- **Talos**: For OS management

## Directory Structure

- `/kubernetes/apps/`: Application deployments by category
  - Each app: `ks.yaml` + `app/` subdirectory with manifests
- `/flux/`: Flux configuration
- `/components/`: Shared components
- `/talos/`: Talos OS configs
- `/bootstrap/`: Initial setup

## Best Practices

1. Follow GitOps principles - repository is source of truth
2. Use declarative YAML for all resources
3. Encrypt secrets with External Secrets Operator
4. Include YAML schema headers for validation
5. Follow sorting rules for consistent formatting
6. Test changes before committing

## Adding New Applications

1. Create directory: `kubernetes/apps/<category>/<app-name>/`
2. Add `ks.yaml` for Flux management
3. Create `app/` with kustomization.yaml, helmrelease.yaml, etc.
4. Include namespace.yaml if needed
5. Configure secrets externally
6. Commit and let Flux reconcile

## YAML Schema Validation

Always include schema headers for validation:
- `# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/...`

See [yaml-schemas.instructions.md](instructions/yaml-schemas.instructions.md) for specific schema URLs.
