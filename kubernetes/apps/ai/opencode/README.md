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
kubectl, yq, jq, gh, op, minijinja-cli, gum, helmfile, helm (~1.5G of
static binaries when last measured; the PVC is 10Gi).

- Tool pins live in `app/mise.yaml` (ConfigMap `opencode-mise`), mounted
  read-only at `~/.config/mise/config.toml` by the `mise-setup` init
  container. The config sets `auto_install = false` so an in-repo exec
  never silently installs the repo checkout's pin set (go/node/python
  compile from source on Alpine).
- **Keep `app/mise.yaml` in sync with the repo `.mise/config.toml`**: the
  Renovate mise manager only sees the root file, and bumps of the shared
  tools are excluded from automerge (`.renovate/autoMerge.json5`), so the
  same reviewed PR must bump both. In-repo `mise exec -- <tool>` fails on
  mismatch; a missing ConfigMap is a hard fail at pod start, not a silent
  fallback to `auto_install = true`.
- `mise-setup` installs the pinned versions and then runs
  `mise prune --tools -y` at boot, after a successful install, dropping
  tool installs no longer pinned by any tracked mise config. Versions
  still tracked by live session worktrees survive by design (verified
  with a `--dry-run` prune on this volume: only one orphan version
  came up). It skips both install and prune unless
  `~/.config/mise/config.toml` is really the mounted ConfigMap — an
  old heredoc-written copy survives on the PVC under the mount, so
  readability alone would not prove the mount is live — so a container
  or Job started without the ConfigMap cannot wipe the
  toolchain (see the 2026-11-23 devclaw incident). When the volume is
  ≥95% full, prune still runs even if the install failed — that is the
  only in-pod lever left. Never run `mise prune` against this volume from
  a Job.
- The `repo-refresh` init container `git pull --ff-only`s the local
  home-ops `main` branch at every boot so sessions start from current
  cluster state (public repo, no token). A detached/non-main checkout or
  a dirty worktree is left alone with a warning.
- `~/.cache/`, `~/.npm/`, `~/.local/share/mise/` and `~/.local/bin/mise`
  are excluded from kopiur backups (all re-creatable: caches rebuild on
  demand, mise reinstalls every boot); the pins themselves live in Git.
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
