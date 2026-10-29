# opencode

OpenCode v2 served from the cluster ([`anomalyco/opencode`](https://github.com/anomalyco/opencode)
image built by joryirving), so sessions, config, skills and the memini memory
plugin are shared by every client that connects to the same server.

## Server

- External UI: `opencode.oxygn.dev` (envoy-external, Kanidm OIDC via
  `components/oidc-kanidm/envoy`) — the v2
  web app adds its own Basic login on top (`opencode` + `OPENCODE_SERVER_PASSWORD`)
- Internal API: `opencode-api.oxygn.dev` (envoy-internal, no gateway policy —
  the v2 server enforces Basic auth itself)

The server password comes from the 1Password item `opencode` (field `password`)
via `externalsecret.yaml` → `OPENCODE_SERVER_PASSWORD`.

## Local CLI client

The CLI cannot do the browser OIDC flow, so it uses the internal route. Requires
the 1Password Desktop app with CLI integration (`op` CLI) so the password is
never stored outside 1Password:

```bash
# ~/.zshrc / ~/.bashrc
opencode-cluster() {
  OPENCODE_SERVER_PASSWORD="$(op read 'op://home-ops/opencode/password')" \
    opencode --server https://opencode-api.oxygn.dev "$@"
}
```

```fish
# ~/.config/fish/config.fish
function opencode-cluster
    env OPENCODE_SERVER_PASSWORD=(op read 'op://home-ops/opencode/password') \
        opencode --server https://opencode-api.oxygn.dev $argv
end
```

Alternatively with direnv:

```bash
# <checkout>/.envrc
export OPENCODE_SERVER_PASSWORD="$(op read 'op://home-ops/opencode/password')"
```

> Sessions, tools and MCP run inside the server pod (project root
> `/home/opencode/projects/home-ops` on the PVC) — the local CLI is a thin
> client; it only renders the UI. The web UI password is the same 1Password
> field.

## Cluster tooling (mise)

The `mise-setup` init container installs [mise](https://mise.jdx.dev) and a
curated toolset on the home PVC at every boot, so agent sessions can run
GitOps validation locally (flate test/diff) and the repo just recipes get
past command-not-found: flate, just, rg, kustomize, vals + talosctl,
kubectl, yq, jq, gh, op, minijinja-cli, gum, helmfile, helm (~780 MB
total, static binaries).

- Session PATH gets `~/.local/bin` + `~/.local/share/mise/shims`, with
  `MISE_AUTO_INSTALL=false`: the repo checkout pins ~25 tools in
  `.mise/config.toml` and go/node/python compile from source on Alpine, which
  would blow the 5Gi PVC budget.
- The init container's `~/.config/mise/config.toml` mirrors the repo
  `.mise/config.toml` pins for the 15 tools it installs. **Keep them in
  sync**: if the repo bumps a pin, in-repo `mise exec -- <tool>` fails (no
  silent fallback) until the init container config is updated to match.
  Renovate bumps for these tools are excluded from automerge
  (`.renovate/autoMerge.json5`) so both files are updated in the same
  reviewed PR.
- `~/.local/bin/mise` and `~/.local/share/mise/` are excluded from kopiur
  backups (re-creatable at boot); `~/.config/mise/` stays backed up, though
  it is also regenerated at every boot (backup only useful for DR).
- The just-recipe CLIs stay credentialless on purpose (no
  kubeconfig/talosconfig/`OP_SERVICE_ACCOUNT_TOKEN`; the litellm MCP gateway
  covers cluster access) — flate itself needs none (static Go binary, no
  kubectl/helm/kustomize); the talos/kube/1Password recipes need their
  config or token supplied to actually run.

## Monitoring

- `opencode-health` HTTPRoute: unauthenticated `opencode.oxygn.dev/global/health`
  (v2 removed `/api/health`) probed by the gatus-sidecar with `[STATUS] == 200`
- `opencode-api` HTTPRoute: probed with `len([BODY]) == 0` (empty-bodied 401
  from the server itself is the expected unauthenticated response)
