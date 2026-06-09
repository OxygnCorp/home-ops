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
