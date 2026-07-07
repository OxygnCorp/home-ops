---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/
# Home Operations - AI Assistant Guide

This is a **Home Kubernetes cluster monorepo** managed with GitOps (Flux, Renovate, GitHub Actions).

## Repository Structure

```
home-ops/
├── kubernetes/           # Kubernetes configurations (Flux-managed)
│   ├── apps/            # Application configs (namespaces as subdirectories)
│   │   ├── ai/          # AI apps (openclaw, toolhive, etc.)
│   │   ├── network/     # Networking (cilium, envoy, etc.)
│   │   ├── observability/ # Monitoring (grafana, prometheus, etc.)
│   │   └── ...         # Other namespaces
│   ├── components/      # Reusable k8s components
│   └── crds/           # Custom CRDs
├── talos/               # Talos Linux machine configs
├── bootstrap/           # Bootstrap templates (helmfile.d, templates)
```

## Key Technologies

| Category   | Tool                         | Purpose                           |
| ---------- | ---------------------------- | --------------------------------- |
| GitOps     | Flux                         | Deploys configs from Git to k8s   |
| CI         | Renovate + GitHub Actions    | Dependency updates, automation    |
| Networking | cilium (eBPF)                | CNI, BGP, service mesh            |
| Ingress    | Envoy Gateway                | L7 proxy, ingress controller      |
| DNS        | external-dns                 | Syncs ingress to Cloudflare/UniFi |
| Secrets    | external-secrets + 1Password   | Secret management                 |
| Storage    | Rook/Ceph + volsync           | Distributed storage + backups    |
| Images     | spegel                       | Local OCI mirror                  |
| IaC        | tofu-controller              | Terraform on k8s                 |
| AI         | toolhive (MCP)              | MCP gateway for AI assistants      |

## GitOps Flow

```
Git push → Flux source sync → Kustomization → HelmRelease → k8s resources
```

Flux recursively searches `kubernetes/apps/` for `kustomization.yaml` files. Each app directory must have a `kustomization.yaml` and `ks.yaml` (Flux Kustomization).

## Conventions

- Component READMEs stay with components (e.g., `kubernetes/apps/ai/toolhive/README.md`)
- Secrets stored in 1Password, referenced via `external-secrets`
- SOPS used for encrypting sensitive values in Git
- Apps use `HelmRelease` via Flux, rarely raw manifests
- Each namespace is a subdirectory under `kubernetes/apps/`

## Common Operations

- **Add app**: Create in `kubernetes/apps/${namespace}/` with kustomization + HelmRelease
- **Update app**: Merge renovate PR or manually edit and push
- **Troubleshoot**: Check `flux get all -n <namespace>`, `kubectl get events --sort-by=.lastTimestamp`
- **Scripts**: `hack/` contains operational scripts (cert-extract.sh, delete-stuck-ns.sh, etc.)
- **Validate locally**: Run `flate` (auto-installed via `.mise.toml`) before pushing GitOps changes:

    ```bash
    # Test Kustomizations + HelmReleases for all clusters
    flate test ks --path ./kubernetes/apps

    # Diff against a baseline (e.g., main branch)
    git worktree add --detach /tmp/baseline origin/main
    flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
    flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
    git worktree remove /tmp/baseline --force
    ```

- **Gateway policy namespace rule**: `ClientTrafficPolicy` and `EnvoyPatchPolicy` that target a `Gateway` must live in the same namespace as that `Gateway`. For `envoy-internal`, put those resources in `kubernetes/apps/network/` with namespace `network`.

## MCP Servers (toolhive)

MCP servers are managed via toolhive in the `ai` namespace:

- **mcp-tools** (default group): arr, ha, memory, seerr
- **mcp-devops** (DevOps group): github, grafana, kubectl, talos

Each MCP server is in `kubernetes/apps/ai/toolhive/mcp-servers/` with its own directory.

## PR Review Standards

When reviewing Renovate PRs, enforce these criteria:

### HelmRelease Requirements

- All applications MUST use `HelmRelease` via Flux, not raw manifests
- Must include `spec.chart.spec.version` for pinned chart versions outside of `app-template`
- Must include `spec.interval` for reconciliation frequency
- Resource limits (CPU/memory) SHOULD be specified for production workloads, but this is not a hard requirement
- `valuesFrom` should reference ConfigMaps/Secrets, not inline values

### Namespace Convention

- `metadata.namespace` is **never** set inline on `HelmRelease` or `Kustomization` resources — this is intentional, not a violation
- The namespace is injected at build time by kustomize's `namespace:` directive in the per-app `kustomization.yaml` (e.g., `namespace: ai`)
- For Flux `Kustomization` resources, `spec.targetNamespace` is propagated automatically via the replacement component at `kubernetes/components/replacements/ks.yaml`
- Reviewers MUST NOT flag missing `metadata.namespace` on these resources as an issue

### Secret Management Rules

- **NEVER** commit plain-text secrets or credentials in Git
- All secrets MUST use `external-secrets` with 1Password backend
- SOPS encryption required for any sensitive values in Git
- If a PR introduces a new secret, verify it's external-secrets backed

### Image & Digest Policy

- Prefer `@sha256:` digests over version tags for reproducibility (container images only)
- OCI artifacts (e.g., Helm charts pulled via `OCIRepository`) are exempt: pin by tag/version, since they don't support SHA-tag references the same way container images do
- For tag-only updates, verify OCI metadata (revision/source/created)
- If revision changes between digests, ensure it's intentional
- Reject updates from untrusted registries (must be allowlisted)
- Preferred registries: GHCR.io, registry.k8s.io, Docker Hub (fallback)
- Avoid Docker Hub for critical infrastructure components

### Breaking Change Detection

Always `request_changes` if:

- API version changes (e.g., `apiVersion: apps/v1beta1` → `apps/v1`)
- Deprecated field usage introduced
- Major version bumps without justification
- CRD changes or custom resource modifications
- Network policy or security context relaxations

### Required Evidence for Approval

Before approving, verify:

1. Release notes/changelog mention the upgrade
2. GitHub compare shows expected changes
3. Version aligns with what Renovate reported
4. No breaking changes identified in release notes
5. Security advisories don't apply to this version

For Helm chart and container image upgrades, you **must** use tool requests (e.g., `gh_api`) to fetch release notes, changelogs, and upstream metadata from the source repository. Do not rely on the PR description alone — verify against the actual upstream release.

_Flux automatically reconciles changes once the PR is merged._

---

## Cluster Topology

The cluster is a 4-node **Talos Linux** cluster running on Proxmox VE 8, semi-hyper-converged:

- **3 control-plane nodes** (HA etcd): `k8s-0`, `k8s-1`, `k8s-2`
- **Workloads + Ceph (block storage) co-located** on the control-plane nodes
- **1 dedicated GPU worker node**: `k8s-3` — tainted `workload=ai:NoSchedule` and reserved for AI workloads (NVIDIA GPU via `nvidia.com/gpu`). Workloads targeting it must set a matching toleration (and usually a `nodeSelector` on `kubernetes.io/hostname: k8s-3`); see the `nvidia-device-plugin` and `toolhive` `EmbeddingServer` for the established pattern
- **Separate NFS server** for file storage (not on Talos nodes)
- **Proxmox VM provisioning** with the QEMU guest agent enabled (`siderolabs/qemu-guest-agent` system extension)
- **PCI passthrough** enabled via kernel args: `intel_iommu=on iommu=pt`
- Schematic: see `talos/schematic.yaml.j2` (sourced from `talosctl talosctl schematic`)

## Day-2 Operational Recipes

Operational tasks are codified in `just` recipes grouped under three modules:

```bash
# Talos node operations (talos/mod.just)
just talos apply-node <node>      # Apply Talos config to a node
just talos reboot-node <node>     # Powercycle reboot
just talos reset-node <node>      # ⚠️ Wipes STATE/EPHEMERAL — destructive
just talos shutdown-node <node>   # Graceful shutdown
just talos render-config <node>   # Render the machineconfig for inspection
just talos schematic-id           # Print the current schematic ID
just talos upgrade-k8s 1.32.4     # Upgrade Kubernetes to a specific version
just talos download-image v1.13.4 # Download the Talos ISO with custom schematic

# Bootstrap (bootstrap/mod.just)
just bootstrap cluster            # Full cluster bootstrap (Talos → k8s → kubeconfig → apps)
```

⚠️ All `just` recipes that mutate state (apply, reboot, reset, upgrade) require interactive confirmation. Always verify the target node before confirming.

## Flux Debug Quickref

Quick commands when a Flux resource is not reconciling correctly:

```bash
# Status overview
flux get kustomizations -A              # All Kustomizations with their Ready status
flux get helmreleases -A                # All HelmReleases
flux get sources all -A                 # GitRepositories, HelmRepositories, OCIRepositories

# Detailed inspection
flux get kustomization <name> -n <ns> -o yaml
flux get helmrelease <name> -n <ns> -o yaml

# Live reconcile
flux logs -f --kind=Kustomization --name=<n> -n <ns>
flux logs -f --kind=HelmRelease --name=<n> -n <ns>
flux reconcile kustomization <name> -n <ns>   # Force re-sync
flux reconcile helmrelease <name> -n <ns>     # Force re-sync

# Suspend / resume
flux suspend kustomization <name> -n <ns>    # Stop reconciling
flux resume kustomization <name> -n <ns>     # Resume
```

For deeper cluster-side investigation, see the `flux-debugger` skill in the agent workspace.

## Component Reference

Reusable Flux components under `kubernetes/components/` are referenced from a `ks.yaml` via the `components:` field:

| Component | Purpose | Used by |
|---|---|---|
| `volsync` | Backup / sync of PVCs (replication sources/destinations) | Most stateful apps |
| `postgres` | CloudNativePG (`postgresql.cnpg.io/v1`) cluster scaffolding with Barman recovery defaults | Apps that need Postgres |
| `zeroscaler` | Scale-to-zero on idle for low-traffic workloads | Job runners, dev tools |
| `alerts` | Bundled `PrometheusRule` definitions for standard app signals | All namespaces with metrics |
| `dragonfly` | P2P image distribution layer (alternative to Spegel for some workloads) | Selected apps |

Example usage in a Kustomization:

```yaml
spec:
  components:
    - ../../../../components/volsync
    - ../../../../components/alerts
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
```

## Secret Rotation (1Password Connect)

Secrets are sourced from 1Password via the `ClusterSecretStore onepassword-connect` and `ExternalSecret` resources. Refresh cadence:

- **Default `refreshInterval`**: `12h` per `ExternalSecret`
- **Force a refresh of one secret**:

  ```bash
  kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s)
  ```

- **Force a refresh of all secrets** (e.g. after rotating the 1Password Connect token):

  ```bash
  kubectl rollout restart deployment -n external-secrets external-secrets
  ```

- **Manual override** (last resort, will not survive reconciliation):

  ```bash
  kubectl create secret generic <name> -n <ns> --from-literal=key=value --dry-run=client -o yaml | kubectl apply -f -
  ```

If a secret has the label `external-secrets.io/managed-by=external-secrets` and the controller sees drift, it will re-sync. See the `external-secrets-troubleshooter` skill for full diagnostics.

## Local Validation with `flate`

`flate` is the local pre-push validation guard. It catches schema errors, broken references, and pinning issues before the change ever reaches Flux.

```bash
# Full cluster validation (~30-60s)
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps

# Single app (faster iteration loop)
mise exec -- flate test hr --path ./kubernetes/apps/<ns>/<app>

# Diff against main before opening a PR
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```

CI also runs `flate test` on every PR via `.github/workflows/flate.yaml`. A green local run is necessary but not sufficient — CI may catch environment-specific schema differences. See the `flate-validator` skill for the full workflow.

## Known Failure Modes

Diagnostic cheat-sheet for the most common issues encountered in this cluster:

| Symptom | First place to look | Reference |
|---|---|---|
| `ImagePullBackOff` on a pod | Spegel + CoreDNS: `kubectl logs -n kube-system -l k8s-app=spegel` | Spegel mirror must be in sync with upstream registry |
| Cilium BGP session down | `kubectl exec -n kube-system ds/cilium -- cilium status` then `cilium bgp peers` | BGP peering is configured per-node; check `CiliumBGPPeerConfig` |
| `ExternalSecret SecretSyncedError` | 1Password Connect logs: `kubectl logs -n external-secrets -l app=onepassword-connect` | Often a token expiry or item path drift |
| `HelmRelease` not Ready, status `False` | `flux get hr <n> -n <ns> -o yaml` → look at `.status.conditions` | `external-secrets-troubleshooter` skill |
| Flux `Kustomization` not Ready | `flux get ks <n> -n <ns> -o yaml` → `.status.conditions[]` | Often a dependency cycle or missing source |
| Pods stuck in `Pending` | `kubectl describe pod <n>` → check `Events` for `FailedScheduling` | Node pressure, taints, or insufficient resources |
| `ceph health` warnings | `kubectl exec -n rook-ceph deploy/rook-ceph-tools -- ceph health detail` | OSD down, MON quorum loss, or PG degradation |
| `etcd` alarms | `talosctl -n <cp-node> etcd alarm list` | `talosctl etcd alarm disarm` after fix |
| 1Password Connect 401 | 1Password → Settings → Connect Servers → check token expiry | `kubectl get secret -n external-secrets onepassword-connect-token -o jsonpath='{.data.token}' | base64 -d` |

## Post-clone Setup

For a fresh clone of the repository:

```bash
# 1. Install pinned tools (node 24, python 3.14, kubectl 1.32, flux 2.8, talosctl 1.13, etc.)
mise install

# 2. Create the (initially empty) secrets env file
touch .secrets.env   # ignored by .gitignore

# 3. Validate before doing anything
mise exec -- flate test ks --path ./kubernetes/apps
```

For a one-shot cluster investigation from the AI agent workspace, no extra setup is required: the agent runs in-cluster and can use `kubectl` / `talosctl` / the `toolhive__*` MCP servers out of the box.

## AI Agent Role

The repository's `ai` namespace hosts the **Puchu** AI agent (this assistant), exposed through the `toolhive` operator. The agent interacts with the cluster via these MCP servers (group `mcp-devops`):

- `github` — repository operations (PRs, issues, code search, releases)
- `grafana` — dashboards, datasources, alert groups
- `kubectl` — cluster inspection (read-only via dedicated ServiceAccount)
- `talos` — Talos node operations

Plus the user-facing group `mcp-default` (Home Assistant, *arr stack, Seerr, memory).

When delegating tasks to the agent, the **branch + PR workflow** applies: every change is on its own branch, and merges go through PR review.
