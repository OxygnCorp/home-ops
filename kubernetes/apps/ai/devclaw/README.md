# devclaw

A second OpenClaw gateway, dedicated to DevOps. It talks to Discord in a
single channel, and reaches the cluster through the litellm MCP gateway
(`http://litellm.ai:4000/mcp`, auth via `LITELLM_API_KEY`) plus a
`GH_TOKEN` for direct GitHub API calls. The personal agents live in
[`../mainclaw`](../mainclaw),
which is a separate gateway with its own channels, plugins and resource budget.

## Discord bot identity

> **One Discord bot application per OpenClaw gateway.** `devclaw` and
> `mainclaw` must never share a `DISCORD_BOT_TOKEN`.

Two gateways connected with the *same* bot token fight over a single Discord
gateway session. Interactions then get answered by whichever instance lost the
race, and that instance replies **"This channel is not allowed."** because the
channel is absent from its own
`channels.discord.guilds.<guild>.channels` allowlist. The native `/models`
picker is the most visible victim: its second step (the *Submit* button) is
re-dispatched internally as a `/model` command, which re-runs every channel
guard.

OpenClaw does not support two gateways on one bot token: the
`/gateway/multiple-gateways` doc requires an isolated profile (and therefore
its own bot token) per instance, and upstream issue #55652 (*"skip channels
claimed by other instances"*) is closed without having been merged.

| Instance  | 1Password item | Discord bot       | Application ID        |
|-----------|----------------|-------------------|-----------------------|
| `mainclaw`| `mainclaw`     | `@claw-assistant` | `1465629115192185057` |
| `devclaw` | `devclaw`      | `puchu`           | `1554384212482723930` |

To rotate or replace the token: create a **separate** Discord application,
invite it to the guild with the `bot` + `applications.commands` OAuth2 scopes,
enable the **Message Content** privileged intent, then update the
`DISCORD_BOT_TOKEN` field of the 1Password item `devclaw`. Never copy
`mainclaw`'s token into it.

## Configuration

`app/resources/openclaw.json` is turned into the `devclaw-configmap` ConfigMap
by the `configMapGenerator` in `app/kustomization.yaml`, then rendered by the
`devclaw-config` ExternalSecret (`templateFrom`) into the `devclaw-config`
secret. The pod copies it to `/home/node/.openclaw/openclaw.json` from the init
container, and re-copies it on every start — `openclaw doctor --fix` may
rewrite that file.

Channel access is a strict allowlist: only `DISCORD_DEVOPS_CHANNEL_ID` is
granted, with `groupPolicy` and `dmPolicy` set to `allowlist` and
`DISCORD_MATT_USER_ID` as the only allowed user. Adding one entry denies every
other channel in the guild — including the ones `mainclaw` serves.

Models come from the cluster LiteLLM proxy (`http://litellm.ai:4000/v1`).
`agents.defaults.modelPolicy.allow` is the list of models the native `/models`
picker may offer; a model outside that list is refused with a *model not
allowed* error (a different failure from the channel allowlist one).

## Secrets

The `devclaw` ExternalSecret (1h) produces the `devclaw-secret` secret, mounted
into the pod through `envFrom`. Values are extracted from the 1Password items
`devclaw`, `litellm` and `memini` (vault `home-ops`, `ClusterSecretStore
onepassword`):

| Secret key                  | 1Password item / field      |
|-----------------------------|-----------------------------|
| `DISCORD_BOT_TOKEN`         | `devclaw` — this app's own bot |
| `DISCORD_GUILD_ID`          | `devclaw`                   |
| `DISCORD_DEVOPS_CHANNEL_ID` | `devclaw`                   |
| `DISCORD_MATT_USER_ID`      | `devclaw`                   |
| `OPENCLAW_GATEWAY_TOKEN`    | `devclaw`                   |
| `GH_TOKEN`                  | `devclaw`                   |
| `LITELLM_API_KEY`           | `litellm` → `KEY_DEVCLAW`   |
| `MEMINI_API_KEY`            | `memini` → `MEMINI_API_KEY` |

A second ExternalSecret, `devclaw-config` (12h), renders the `devclaw-config`
secret from the `devclaw-configmap` ConfigMap (`resources/openclaw.json`). That
is where `DEVCLAW_TRACING_KEY` lands: the file carries
`"Authorization": "Bearer {{ .DEVCLAW_TRACING_KEY }}"`, resolved from the
`lens` item, so the key is only ever present in the rendered secret — never in
the ConfigMap, the pod env, or Git. Because of the 12h refresh, an
`openclaw.json` change committed to Git reaches the pod at the next sync; force
it with `kubectl annotate externalsecret devclaw-config -n ai force-sync=$(date +%s)`
(a missing `DEVCLAW_TRACING_KEY` field fails this sync and freezes the rendered
config).

The HelmRelease carries
`secret.reloader.stakater.com/reload: "devclaw-secret, devclaw-config"`, so a
1Password change restarts the pod automatically. To force a refresh:

```bash
kubectl annotate externalsecret devclaw -n ai force-sync=$(date +%s)
```

> **Keep every field when editing the item `devclaw`.** If a field referenced by
> the template disappears, external-secrets fails the whole sync with
> `map has no entry for key "<FIELD>"` and the `ExternalSecret` goes
> `Ready=False (SecretSyncedError)` — which freezes every value, including a
> token that was just updated. Re-creating or deleting a section in the 1Password
> UI drops its fields, so check `kubectl get externalsecret devclaw -n ai` after
> any edit.

## Operations

- The gateway only listens on `18789` after a slow `doctor`/migration phase
  (~8 min). The readiness probe deliberately keeps the pod `NotReady` during
  that window so Envoy does not route to a dead upstream.
- Logs: `kubectl logs -n ai deploy/devclaw -c app -f` (`OPENCLAW_LOG_LEVEL=debug`).
  Confirm the bot identity with `client initialized as <application id>`.
- `memini` is installed at startup by the app command, version-guarded against
  `.clawver` so normal restarts stay offline; Renovate tracks the pinned version.

## Disk hygiene

The state PVC is 10Gi. The `init` container prunes only what is re-downloadable
or superseded, on every start:

| Path | Rule |
|---|---|
| `~/.npm/_cacache` | dropped whole once it exceeds 500M (a per-file prune would leave dangling index entries) |
| `~/.npm/_logs` | files older than 7 days |
| `~/.openclaw/tmp/plugin-captures/*` | entries older than 7 days |
| `~/.openclaw/agents/*/session-sqlite-import-archive/*` | files older than 30 days: the JSONL is already imported into sqlite, so the window only preserves a month-old rollback |
| `~/.openclaw.update-captures/doctor-*` | newest kept plus the last 7 days (upstream calls these recovery artifacts, not temp files) |

Mise tool versions are handled separately, see below.

## Toolchain

`mise/config.toml` (this directory) is the referential for the CLIs the agent
uses. It is mounted read-only at `~/.config/mise/config.toml`, so an agent
cannot edit a pin with `mise use -g`: a version bump is a commit. (`~/.config/mise/conf.d/`
stays writable and mise loads it before `config.toml`, so an agent that really
wanted another tool version could still add one there — the mount protects the
pins, not the whole toolchain.) Renovate
maintains the pins through its native mise manager — the same one that keeps the
repo-root `.mise/config.toml` current — and opens a PR per bump. Bumps here
automerge after a 24h soak, minor and patch only (only the root file needs a
human, because it shares tools with the opencode pod's `mise-setup` heredoc); a
major stays a manual PR. A merged bump reaches the pod because
the `devclaw-mise` ConfigMap is listed in the Reloader annotation — a `subPath`
mount is never refreshed in place, and the hash-free ConfigMap name means the
pod template does not change on its own.

The `app` container runs `mise install` at startup (idempotent, instant once
satisfied) so a pin bumped by Renovate is satisfied even when its tool is not
yet on the volume, and `mise prune --tools -y` when the volume passes 80%:
versions this config no longer pins are reclaimed, while tools an agent installs
ad hoc survive until the room is actually needed. The prune normally only runs
after a successful install, so a failed download of a freshly bumped pin can
never cost the agent the older version it was still using — but a full volume is
itself what makes `mise install` fail, so above 95% the prune runs anyway rather
than waiting for a human. Both steps warn and continue rather than block the
gateway.

Both steps are also skipped unless `~/.config/mise/config.toml` is readable.
That file only exists while the ConfigMap is mounted: on the bare volume (a
maintenance Job, a container started without the mount) `mise install` is a
no-op and `mise prune` sees every installed version as untracked, so it deletes
the whole toolchain. That is not theoretical — a prune run from a Job against
this PVC did exactly that on 2026-11-23. Consequence for maintenance: never run
`mise prune` from a Job against this volume; if the toolchain has to be
reclaimed, do it from inside the pod or by deleting the specific install
directories.

Node, unlike the rest of the list, is not pinned at all: the openclaw image
already ships Node 24.22.1 at `/usr/local/bin/node` (OCI label `base.name` =
`node:24.22.1-trixie-slim`). A mise-managed node shadows it, because
`~/.local/share/mise/shims` precedes `/usr/local/bin` in `PATH`, and that is
what turned the routine `node` 24 -> 26 bump in #5980 into a crash-loop: v26
needs `libatomic.so.1`, the image does not carry it, and every `node` call
exited 127 (fixed by reverting the pin in #5994, then dropping it here). The
startup script deletes any `shims/node` (plus the npm/npx/corepack shims mise
writes for the node tool) left on the volume before the gateway starts, and
`MISE_DISABLE_TOOLS=node` in the container env stops mise from installing or
shimming node again, so `node` always resolves to the image's own runtime. Do
not re-add a pin: the image is the single source of truth for the Node the
gateway runs on, which also means a Node upgrade rides an image bump, not a
Renovate mise PR.

The list deliberately omits what an MCP server already covers — `kubescape`
(radar: posture checks), `stern` (radar: log reading), `k9s` (a TUI, no agent
use), `aws-cli` (nothing in this repo talks to AWS) and `kubectl` (no kubeconfig
on the volume, and without one it falls back to `localhost:8080` instead of the
pod's service account — verified. Making it work would mean shipping an
in-cluster kubeconfig, which would hand this pod a second, unmetered cluster
write path next to the MCP gateway, the only sanctioned one). Keep that in mind
when adding a tool: a capability the gateway exposes costs no volume space.

If the volume still needs room, drop a pin here (its versions are reclaimed by
the next pressure prune) or raise the PVC.

## Related

- Flux `Kustomization`: `ks.yaml` (namespace `ai`, `interval: 1h`,
  `postBuild` `APP=devclaw`).
- PVC backups: the `kopiur/backup` component (`KOPIUR_CAPACITY=10Gi`).
