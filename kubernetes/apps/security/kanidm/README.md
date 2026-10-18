# Kanidm

OIDC identity provider for the cluster's single sign-on (replacement for the
removed Authentik). Two workloads in one HelmRelease (chart `bjw-s-labs
app-template`):

- `kanidm` — StatefulSet running `docker.io/kanidm/server` on its own TLS
  (`Certificate` `idm-oxygn-dev` via `letsencrypt-production`, validated
  upstream by `BackendTLSPolicy` `kanidm-upstream`). Data on the
  `components/kopiur/backup` PVC (hourly Kopia snapshots to NFS).
- `provision` — [`ghcr.io/m00nwtchr/kanidm-provision`](https://github.com/m00nwtchr/kanidm-provision):
  watches ConfigMaps labeled `kanidm_config: "1"` in namespace `security`
  (created per-app by `components/oidc-kanidm/base`), applies the declarative
  OAuth2 client state to Kanidm via its authenticated API
  (`kanidm-provision` service-account token), and writes each client's
  `client-id` / `client-secret` into the app's namespace
  (Secret `kanidm-${APP}-oidc`, referenced by the app's `SecurityPolicy`).
  The pinned digest is the sidecar build (`src/bin/sidecar/k8s.rs`), the
  variant running in production in eleboucher's homelab against Kanidm
  1.11.x; its binary carries the k8s watcher, the `kanidm-${APP}-oidc`
  secret naming and the `/_basic_secret` API path (binary-verified).
  Runs under its own ServiceAccount (cluster-wide create/patch Secrets,
  namespaced read of ConfigMaps in `security`) — the `kanidm` server pod
  itself runs without a token. Upstream publishes on Docker Hub only
  (fallback registry per the repo image policy — no GHCR mirror exists).

Public endpoint: `https://idm.oxygn.dev` (envoy-external; the DNS record is
created by external-dns).

## Initial setup

### 1. Recover the built-in admin accounts

After first deployment:

```bash
kubectl exec -n security -it statefulset/kanidm -- kanidmd recover-account admin
kubectl exec -n security -it statefulset/kanidm -- kanidmd recover-account idm_admin
```

Log in with each recovery token and set a real password via the web UI at
`https://idm.oxygn.dev/ui/reset`.

### 2. Create the provision service account

```bash
kubectl exec -n security -it statefulset/kanidm -- kanidm service-account create kanidm-provision "Kanidm Provision" idm_admins -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm group add-members idm_admins kanidm-provision -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm service-account api-token generate --readwrite kanidm-provision provision-token -D idm_admin
```

Store the generated token in 1Password as item **`kanidm-provision`**, field
`token`. The `ExternalSecret` `kanidm-provision-token` picks it up within
1h (annotate `force-sync` to speed up); the `provision` controller decrashloops.

### 3. Create the groups and the first user

```bash
kubectl exec -n security -it statefulset/kanidm -- kanidm group create users -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm group create admins -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm person create <username> "<Display Name>" -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm person update <username> --mail "<email>" -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm group add-members users <username> -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm group add-members admins <username> -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm group add-members idm_admins <username> -D idm_admin
kubectl exec -n security -it statefulset/kanidm -- kanidm person credential create-reset-token <username> -D idm_admin
```

Enrol a password and/or passkey via the printed reset URL.

## Troubleshooting

- `provision` pod crashlooping → `kanidm-provision-token` missing: create the
  1Password item (step 2) and `kubectl -n security annotate externalsecret
  kanidm-provision-token force-sync=$(date +%s)`.
- Envoy discovery failures during Kanidm TLS-secret rollouts: the
  `SecurityPolicy`s produced by `components/oidc-kanidm/envoy` pin the
  authorization and token endpoints explicitly, so Envoy never re-discovers —
  a gateway re-translate is enough after a rollout, per the component README.
