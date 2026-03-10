---
applyTo: "**/*"
---

# Repository Structure and Operations Guide

This guide provides an overview of the home-ops repository structure and operations, designed to help AI assistants understand how to implement new applications or make adjustments to existing ones. The repository follows GitOps principles using Flux for continuous deployment on a Kubernetes cluster.

## Repository Overview

This is a GitOps-managed Kubernetes cluster configuration repository. It uses:
- **Flux**: For continuous deployment and reconciliation
- **Kustomize**: For resource customization and patching
- **Helm**: For application packaging (via HelmReleases)
- **External Secrets Operator**: For managing secrets from external providers
- **Talos**: For OS management on cluster nodes

## Key Directories and Structure

### `kubernetes/`
Contains all Kubernetes manifests and configurations.

#### `kubernetes/apps/`
Application deployments organized by category:
- Each app has its own subdirectory (e.g., `kubernetes/apps/media/plex/`)
- Structure per app:
  - `ks.yaml`: Flux Kustomization resource that manages the app deployment
  - `app/`: Subdirectory containing app-specific resources
    - `kustomization.yaml`: Kustomize configuration for combining app resources
    - `helmrelease.yaml`: HelmRelease definition (if using Helm)
    - `ocirepository.yaml`: OCIRepository for pulling Helm charts from OCI registries
    - `*.yaml`: Additional resources like PVCs, ConfigMaps, Secrets, etc.

Categories include:
- `actions-runner-system/`: CI/CD runners
- `ai/`: AI-related applications (Ollama, OpenWebUI, etc.)
- `automation/`: Home automation (Home Assistant, TeslaMate, etc.)
- `cert-manager/`: Certificate management
- `database/`: Database services
- `download/`: Download managers and indexers
- `external-secrets/`: Secret management
- `flux-system/`: Flux itself
- `kube-system/`: Core Kubernetes components
- `media/`: Media servers and tools
- `network/`: Networking and DNS
- `observability/`: Monitoring and logging
- And more...

### `flux/`
Flux configuration files:
- `flux/cluster/`: Cluster-wide Flux resources

### `components/`
Reusable components and shared configurations:
- `alerts/`: Alerting rules
- `nfs-scaler/`: NFS scaling configurations
- `volsync/`: Volume synchronization

### `talos/`
Talos OS configurations:
- `machineconfig.yaml.j2`: Machine configuration template
- `nodes/`: Node-specific configurations

### `bootstrap/`
Initial cluster setup:
- `resources.yaml.j2`: Bootstrap resources template
- `helmfile.d/`: Helmfile configurations for initial setup

### `scripts/`
Utility scripts:
- `bootstrap-cluster.sh`: Cluster bootstrapping script

## Core Concepts

### Kustomizations
- Each app directory contains a `kustomization.yaml` that defines how resources are combined
- Uses patches, overlays, and resource references
- Allows customization of Helm releases and other resources

### Flux (GitOps)
- Flux watches this repository for changes
- Automatically reconciles cluster state with repository state
- Uses `HelmRelease` resources for Helm deployments
- Supports dependencies between resources

### Flux Kustomizations
- `ks.yaml` files are Flux Kustomization resources that manage app deployments
- They define reconciliation intervals, dependencies, and the path to the app's resources
- Allow for automated deployment and updates via GitOps

### OCIRepositories
- `ocirepository.yaml` files define OCI repositories for pulling Helm charts
- Used for charts hosted on OCI registries (e.g., GHCR)
- Specify the URL, tag, and other pull parameters

### External Secrets
- Manages secrets from external providers (e.g., 1Password)
- `external-secrets/` directory contains ESO configurations
- Secrets are referenced in applications via `Secret` resources

### Components
- Shared, reusable configurations
- Can be included in multiple applications
- Examples: alerting rules, volume management

## Adding a New Application

To add a new application:

1. **Choose or create a category** under `kubernetes/apps/`
2. **Create app directory**: `kubernetes/apps/<category>/<app-name>/`
3. **Add namespace**: Create `namespace.yaml`
4. **Create kustomization**: `kustomization.yaml` that includes all resources
5. **Add HelmRelease** (if using Helm): `helmrelease.yaml` with chart details
6. **Configure resources**: Add any additional ConfigMaps, Secrets, etc.
7. **Handle secrets**: If needed, configure external secrets
8. **Update Flux**: Ensure Flux can reconcile the new resources
9. **Test**: Validate with `kubectl` or Flux commands

### Example: Adding a Simple App

Create the directory structure: `kubernetes/apps/<category>/<app-name>/`

#### `ks.yaml` (Flux Kustomization)
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: my-app
  namespace: my-app
spec:
  interval: 30m
  path: ./kubernetes/apps/<category>/<app-name>/app
```

#### `app/namespace.yaml`
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/v1/namespace.json
apiVersion: v1
kind: Namespace
metadata:
  name: my-app
```

#### `app/kustomization.yaml`
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
  - ocirepository.yaml
```

#### `app/ocirepository.yaml`
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: my-app
spec:
  interval: 15m
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
  ref:
    tag: latest
```

#### `app/helmrelease.yaml`
```yaml
# yaml-language-server: $schema=https://k8s-schemas.oxygn.dev/helm.toolkit.fluxcd.io/helmrelease_v2beta1.json
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: my-app
  namespace: my-app
spec:
  chart:
    spec:
      chart: my-app
      sourceRef:
        kind: OCIRepository
        name: my-app
  interval: 15m
  values:
    # app-specific values
```

## Modifying Existing Applications

- Locate the app in `kubernetes/apps/<category>/<app-name>/`
- Edit the relevant files (kustomization.yaml, helmrelease.yaml, etc.)
- For Helm apps, modify values in `helmrelease.yaml`
- Use Kustomize patches for customizations
- Commit changes; Flux will reconcile automatically

## Best Practices

- Follow existing naming conventions
- Use Kustomize for environment-specific customizations
- Store secrets externally via External Secrets Operator
- Test changes in a development environment if possible
- Use the provided instruction files for sorting and formatting YAML files
- Reference components for shared functionality

## Tools and Commands

- `just`: Task runner for common operations (see mod.just files)
- `kubectl`: Direct cluster interaction
- `flux`: Flux CLI for GitOps operations
- `helm`: Helm CLI for chart management

## Additional Resources

- Flux documentation: https://fluxcd.io/
- Kustomize documentation: https://kubectl.docs.kubernetes.io/references/kustomize/
- External Secrets Operator: https://external-secrets.io/
