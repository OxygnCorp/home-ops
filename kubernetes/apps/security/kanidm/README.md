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

Everything below is automated in `kanidm/mod.just` (modeled on vrozaksen's
home-ops): **one command**. It needs an authenticated `op` CLI (the break-glass
passwords and the provision token go straight to 1Password).

```bash
just kanidm bootstrap
```

What it does:

1. `kanidmd recover-account admin` / `idm_admin` (Kanidm 1.11 prints a JSON
   `output` — that is a **generated password**, not a `/ui/reset` token; the
   reset-token flow only applies to `person` accounts) → stores both in the
   1Password item **`kanidm`** (`ADMIN_PASSWORD`, `IDM_ADMIN_PASSWORD`).
2. Creates the `kanidm-provision` service-account + `provision-token` API token
   (CLI runs locally if installed, otherwise in a throwaway
   `docker.io/kanidm/tools` pod; auth via the hidden `KANIDM_PASSWORD`
   global — non-interactive) → stores the token in the 1Password item
   **`kanidm`** (`PROVISION_TOKEN` field).
3. Force-syncs the `kanidm-provision-token` ExternalSecret and waits for the
   `kanidm-provision` deployment to roll out.

Then onboard yourself (password + passkey via the printed reset link — open it
after ~3 minutes, the token has a delayed validity):

```bash
just kanidm onboard <username> "<Display Name>" <email>
```

Other recipes: `bulk people.csv`, `reset <user>`, `group-add`, `group-rm`,
`members`, `list`, `get`.

## Troubleshooting

- Locked out of an app (stale/revoked session): you do NOT need to clear
  all cookies. For apps using `components/oidc-kanidm/envoy` (SecurityPolicy
  on the HTTPRoute), Envoy Gateway's OIDC filter exposes `logoutPath:
  /logout` — visit `https://<app-host>/logout` to clear that app's
  credential cookies and get a fresh authorization flow. Apps wired with
  `components/oidc-kanidm/in-app` have no gateway `/logout`; clear that
  app's cookies in the browser instead.
- Forced re-auths (rotation race): Kanidm rotates refresh tokens with
  reuse-detection — a reused token revokes the whole session. While there
  are >= 2 gateway data planes, concurrent refreshes of the same session
  can trip reuse-detection. Until the front-end auth design changes
  (oauth2-proxy or in-app flows), the gateways run a *single* replica with
  `strategy: Recreate` (see `envoy-gateway` EnvoyProxy); budget a short
  ingress blip during proxy image bumps instead of session churn.
- Node drains on the node hosting kanidm are intentionally blocked by
  `PodDisruptionBudget kanidm` (maxUnavailable: 0): Kanidm is the cluster's
  only auth authority and 1 instance only. Lift it explicitly
  (`kubectl patch pdb/kanidm ...`) for a planned drain.
- `provision` pod crashlooping → `kanidm-provision-token` missing: add the
  `PROVISION_TOKEN` field to the 1Password item `kanidm` and `kubectl -n
  security annotate externalsecret kanidm-provision-token
  force-sync=$(date +%s)`.
- Envoy discovery failures during Kanidm TLS-secret rollouts: the
  `SecurityPolicy`s produced by `components/oidc-kanidm/envoy` pin the
  authorization and token endpoints explicitly, so Envoy never re-discovers —
  a gateway re-translate is enough after a rollout, per the component README.
