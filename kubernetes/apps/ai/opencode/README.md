# opencode

OpenCode v2 served from the cluster ([`anomalyco/opencode`](https://github.com/anomalyco/opencode)
image built by joryirving), so sessions, config, skills and the memini memory
plugin are shared by every client that connects to the same server.

## Server

- External UI: `opencode.oxygn.dev` (envoy-external, Authentik OIDC) — the v2
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

## Monitoring

- `opencode-health` HTTPRoute: unauthenticated `opencode.oxygn.dev/global/health`
  (v2 removed `/api/health`) probed by the gatus-sidecar with `[STATUS] == 200`
- `opencode-api` HTTPRoute: probed with `len([BODY]) == 0` (empty-bodied 401
  from the server itself is the expected unauthenticated response)
