# mainclaw: mise-managed CLI tools (op, gh) — Design

Date: 2026-08-28
Status: Approved
Scope: `kubernetes/apps/ai/mainclaw/`

## Problem

The openclaw agent in mainclaw needs CLI binaries not shipped in the upstream
`ghcr.io/openclaw/openclaw` image — primarily `op` (1Password CLI). Current
state on the PVC:

- `op` is declared in `~/.config/mise/config.toml` (`op = "2.34.1"`) but mise
  reports it **missing** — the shim `/home/node/.local/bin/op` dangles and the
  binary is unusable.
- The existing alpine `init` initContainer invokes `curl`, which is not
  present in stock `docker.io/library/alpine` — the mise auto-install step can
  never succeed on a fresh/restored PVC (currently masked by the
  `[ ! -f ... ]` guard).
- `OP_SERVICE_ACCOUNT_TOKEN` is already injected via `mainclaw-secret`
  (`externalsecret.yaml`), so headless auth is ready; only the binary is
  missing.

## Chosen approach (Option B: initContainer installs into the PVC, mise-driven)

Alternatives considered and rejected:

| Option | Verdict |
|---|---|
| A. Custom image + GitHub Actions | No image-build CI exists in repo; lags weekly upstream openclaw releases; overkill for a few binaries |
| C. Sidecar with the binary | Sidecars do not share filesystem/exec — cannot expose a CLI to the app container |
| D. initContainer copying binary from an image | No official `1password/cli` image exists (verified); would require building one → option A |
| E. ExternalSecrets/Connect only | Rejected as primary path — agent invokes the CLI directly; kept for auth (service account token already present) |

Rationale for B: the deployment already runs mise on the PVC, `PATH` already
resolves mise shims, and `.local/share/` (mise store) is already excluded from
kopia snapshots with the comment "can be reinstalled via mise install".

## Design

### 1. Declarative tool list — ConfigMap `mainclaw-mise`

New file `kubernetes/apps/ai/mainclaw/app/mise.yaml` (ConfigMap, key
`config.toml`):

```toml
[tools]
op = "2.39.0"   # latest stable, verified against AgileBits feed
gh = "2.98.0"   # latest stable via mise ls-remote; backend aqua:cli/cli
```

Mounted read-only and pointed at by `MISE_GLOBAL_CONFIG_FILE` env var. It
overrides the PVC-local `~/.config/mise/config.toml` (which currently holds
the stale `op = "2.34.1"` declaration). Adding a tool later = one line here.

### 2. initContainer `install-tools`

New initContainer using the **openclaw image** (same pinned digest as the app
container — has curl; alpine does not):

```sh
export PATH=/home/node/.local/bin:$PATH
export MISE_GLOBAL_CONFIG_FILE=/etc/mise/config.toml
if [ ! -f /home/node/.local/bin/mise ]; then
  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/home/node/.local/bin/mise sh
fi
mise install --yes
```

- `mise install` (no args) installs/repairs every tool declared in the global
  config; already-correct versions are skipped → normal restarts stay offline.
- Version bump = edit ConfigMap → next pod start reinstalls.
- The broken `curl mise.run` step is removed from the existing alpine `init`
  container (which keeps only the config-file permission work).

### 3. kopia snapshots

No changes required: binaries live under `.local/share/mise/` (already in
`.kopiaignore`, restorable via `mise install`). Shims in `.local/bin/` are
~37-byte symlinks and `pip`-installed agent tooling also lives there and
should remain backed up. `.local/bin/` is therefore NOT ignored.

### 4. Renovate

Renovate's `mise` manager parses the config: `gh` (aqua backend →
github-releases) should auto-bump. `op` (vfox/aqua:1password backends) may not
resolve to a datasource — verify post-merge; fall back to manual bumps (same
as today).

### 5. Explicitly out of scope

- `docker` CLI: not in the mise registry; dind sidecar (as in the reference
  repo) is a separate decision.
- `go`, homebrew: heavy on the PVC; `go` can be added later via one mise line
  if needed.

## Testing / validation

1. `mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw`
2. `flate diff hr` vs main baseline
3. Post-merge: pod restarts, init `install-tools` completes, then
   `kubectl exec -n ai deploy/mainclaw -c app -- op --version` → `2.39.0`
4. Restart pod again → confirm no re-download (offline fast path).
