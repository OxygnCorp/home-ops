# Bootstrap

One-time cluster bring-up. This directory installs the minimal runtime base a fresh Talos cluster needs; once `flux-instance` is healthy, [Flux](https://fluxcd.io) takes over and reconciles everything else from `kubernetes/` in Git.

Run it with:

```sh
just bootstrap cluster
```

## Stages

`cluster` chains the private stages below, in order:

| Stage        | What it does                                                                                                                                          |
|--------------|-------------------------------------------------------------------------------------------------------------------------------------------------------|
| `nodes`      | `talosctl apply-config --insecure` on every node in talosconfig. Already-configured nodes (`certificate required`) are skipped, so this is idempotent. |
| `k8s`        | `talosctl bootstrap` on the controller endpoint, retried until etcd answers `AlreadyExists`.                                                          |
| `kubeconfig` | Fetch the kubeconfig into the repo root. The optional `lb` argument (default `cilium`) re-points the `main` cluster context at `https://<controller>:6443` before the Cilium service LB exists. |
| `base`       | `kustomize build kustomize/apps` → namespaces + secrets (rendered through minijinja + `vals`), then `helmfile crds.yaml` for out-of-band CRDs.         |
| `apps`       | `helmfile apps.yaml sync` — installs the core releases in dependency order (see below).                                                                |
| `kubeconfig` | Re-fetch the kubeconfig, this time keeping the Cilium LoadBalancer endpoint.                                                                          |

## base: namespaces, secrets and CRDs

`kustomize/apps` applies:

- `components/namespace` — cluster namespaces (`prune: disabled`, they outlive Flux)
- `apps/external-secrets` — 1Password Connect credentials for the `ClusterSecretStore`
- `apps/network` — Cloudflare tunnel identity

Secrets are `ref+op://...` references resolved at render time by `just template` (`minijinja-cli` → `vals eval`); nothing sensitive is stored in Git. Note the **double prefix** `ref+ref+op://` used in `kustomize/**/secret.yaml` — the outer `ref+` is consumed by `vals` first, handing the inner `ref+op://` reference to the 1Password provider. Elsewhere (e.g. the Talos machine config) the single `ref+op://` form is used.

`helmfile/crds.yaml` installs CRDs **out-of-band** (envoy-gateway, grafana-operator, kube-prometheus-stack): only the rendered CRDs are piped to the cluster, never the releases. This guarantees the CRDs exist before Flux starts reconciling workloads that reference them, avoiding `dependsOn` chains on nearly every CRD-consuming Kustomization.

## apps: the core release chain

`helmfile/apps.yaml` installs, via `needs` ordering:

```text
cilium → coredns → spegel → cert-manager → external-secrets
       → onepassword-connect → flux-operator → flux-instance
```

- **cilium** postsync hooks wait for the BGP CRDs, then apply `kubernetes/apps/kube-system/cilium/app/networking.yaml` (BGP peering, LB pools) that the cluster needs before nodes go `Ready`.
- **onepassword-connect** postsync hook applies the app's `clustersecretstore.yaml` so secrets resolve as soon as external-secrets is up.
- **flux-operator + flux-instance** install Flux itself; from this point Flux owns the application stack and this directory is no longer consulted.

## Single source of truth

The helmfile templates read each release's chart and values **from the app's own GitOps manifests** — no duplication:

- `templates/release.yaml.gotmpl` reads `spec.url` / `spec.ref.tag` from `kubernetes/apps/<ns>/<app>/app/ocirepository.yaml`
- `templates/values.yaml.gotmpl` reads `spec.values` from `kubernetes/apps/<ns>/<app>/app/helmrelease.yaml`

The bootstrap therefore installs exactly the objects Flux will later reconcile. Renovate bumps in `kubernetes/apps/` flow into the next bootstrap automatically.

## Re-bootstrap

`just bootstrap cluster` is safe to re-run on an existing cluster: the `nodes` stage skips configured nodes, `k8s` short-circuits on `AlreadyExists`, and the helmfile syncs converge to the declared state. Point `talosconfig` at the controller endpoint and ensure 1Password Connect credentials are reachable before starting.
