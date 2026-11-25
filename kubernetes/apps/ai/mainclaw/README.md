# mainclaw

The personal OpenClaw gateway: one Discord bot (`@claw-assistant`) fronting
several long-lived agents, each with its own workspace and sqlite database on a
20Gi PVC. Models go through litellm, cluster access through the litellm MCP
gateway. The DevOps-facing twin lives in [`../devclaw`](../devclaw).

## Per-agent model keys

Each agent has its own LiteLLM virtual key (`Mainclaw-<agent>`) so model spend
can be attributed per agent. The `mainclaw` ExternalSecret exposes one env var
per key; `resources/openclaw.json` defines a matching `litellm-<agent>` provider
(same base URL and session header, dedicated key, `dsv41f` only) and points the
agent's primary model and subagents at it. Fallbacks use the gateway-wide
`litellm` provider, which keeps `LITELLM_API_KEY` / `KEY_MAINCLAW`.

| Agent | Env var | 1Password field |
|---|---|---|
| `main` | `LITELLM_API_KEY_MAINCLAW_MAIN` | `KEY_MAINCLAW_MAIN` |
| `family` | `LITELLM_API_KEY_MAINCLAW_FAMILY` | `KEY_MAINCLAW_FAMILY` |
| `coach` | `LITELLM_API_KEY_MAINCLAW_COACH` | `KEY_MAINCLAW_COACH` |
| `finance` | `LITELLM_API_KEY_MAINCLAW_FINANCE` | `KEY_MAINCLAW_FINANCE` |
| `shopping` | `LITELLM_API_KEY_MAINCLAW_SHOPPING` | `KEY_MAINCLAW_SHOPPING` |
| `media` | `LITELLM_API_KEY_MAINCLAW_MEDIA` | `KEY_MAINCLAW_MEDIA` |
| `nova` | `LITELLM_API_KEY_MAINCLAW_NOVA` | `KEY_MAINCLAW_NOVA` |
| `lycos` | `LITELLM_API_KEY_MAINCLAW_LYCOS` | `KEY_MAINCLAW_LYCOS` |
| `legal` | `LITELLM_API_KEY_MAINCLAW_LEGAL` | `KEY_MAINCLAW_LEGAL` |
| `elina` | `LITELLM_API_KEY_MAINCLAW_ELINA` | `KEY_MAINCLAW_ELINA` |
| `elliot` | `LITELLM_API_KEY_MAINCLAW_ELLIOT` | `KEY_MAINCLAW_ELLIOT` |

`agents.defaults.model`, `agents.defaults.subagents.model` and
`agents.defaults.imageModel` stay on the global provider: agents added later,
delegated subagents without an explicit override, and image analysis are not
attributed per agent. MCP tool calls (`mcp.servers.litellm`) also keep the
gateway-wide key — only model traffic is split.

### Rollout ordering

The `litellm` and `mainclaw` Kustomizations are applied independently, and the
11 `PushSecret`s need up to an hour to publish `KEY_MAINCLAW_*` to 1Password.
If `mainclaw-config` lands first, the reloader rolls the pod with the new
providers but without their env vars, so each agent gets a 401 and falls back
to the global key (mis-attributed spend) until the `mainclaw` ExternalSecret
refreshes. After merging a change here:

1. Wait for all 11 `LiteLLMVirtualKey` and `PushSecret` objects to be Ready.
2. `kubectl annotate externalsecret mainclaw -n ai force-sync=$(date +%s)`
   and confirm the new env var is present in `mainclaw-secret`. Also confirm
   the ExternalSecret itself is `Ready`: `OP_SERVICE_ACCOUNT_TOKEN` still
   resolves from the `mainclaw` item now that the `litellm` item is no longer
   extracted wholesale.
3. Only then `kubectl annotate externalsecret mainclaw-config -n ai force-sync=$(date +%s)`.

Attribution is best-effort, not a security boundary: all keys are resolved by
the same gateway process, and the env allowlist lets any agent read another
agent's key. The split is there to measure spend, not to isolate agents.

## Agent-to-agent access

Only the two orchestrators can start a cross-agent conversation: `main` and
`nova` may send to any of the other ten agents, while the nine specialists
(`family`, `coach`, `finance`, `shopping`, `media`, `lycos`, `legal`, `elina`,
`elliot`) can only reply. This is enforced by three OpenClaw settings:

- `tools.sessions.visibility: agent` keeps each agent's session history private;
  a delegated call returns the reply without exposing the other agent's history.
- `tools.agentToAgent.allow` lists all eleven agents, so the global policy does
  not block a permitted pair.
- each specialist has `tools.agentToAgent.send: []`; `main` and `nova` list the
  other ten. `main` and `nova` also get `subagents.allowAgents` with all eleven
  ids so they can spawn the specialists explicitly.

This policy covers `sessions_send` and `sessions_spawn` only. It does **not**
cover outbound A2A calls, which use the `message` tool with an `a2a:<peer>`
target: those run at gateway level and every agent in the gateway shares the
same outbound peer token. Use separate gateways if A2A egress must be isolated
per agent.

When adding an agent, update all five lists: the global `agentToAgent.allow`,
the `send` lists on `main` and `nova`, and their `subagents.allowAgents`. An
agent missing from a list is silently unreachable (fail-closed).

## A2A exposure

The gateway exposes every agent over A2A on the gateway port. The bundled `a2a` channel plugin is enabled in `plugins.allow` and
`plugins.entries`. The public card
is served at `/.well-known/agent-card.json`; JSON-RPC calls go to
`POST /a2a/v1` with the peer token as a bearer token. Replies may take up to
ten minutes (`replyTimeoutMs: 600000`). `channels.a2a` maps one peer to one
agent, and a matching binding routes that peer to the agent:

- peer `litellm-main` → `main`, `litellm-family` → `family`, and so on for the
  eleven agents;
- each peer token is read from `A2A_MAINCLAW_<AGENT>_TOKEN`, which the
  `mainclaw` ExternalSecret maps from the 1Password `litellm` item;
- `exposeAgents` lists all eleven agents on the card.

LiteLLM registers the same agents as `mainclaw-<agent>` and probes the
gateway origin `http://mainclaw-app.ai.svc.cluster.local:18789` for the card,
which advertises `/a2a/v1`. The peer token selects the route, not the card
skill, so adding an agent means updating seven touchpoints: the peer, its
token, the ExternalSecret entry, the binding, `channels.a2a.exposeAgents`,
`secrets.providers.default.allowlist`, and the LiteLLM registry entry.

Outbound peers `hermes` and `hermes-foyer` point at the LiteLLM broker
(`http://litellm.ai:4000/a2a/hermes-default` and `/a2a/hermes-foyer`). Agents
use them with the `message` tool and target `a2a:hermes` or
`a2a:hermes-foyer`; the outbound token is the gateway-wide `LITELLM_API_KEY`,
so outbound delegation is attributed to the global key, not to the calling
agent. Every agent shares that egress identity. The peer `token` on those
outbound entries is a dedicated random value, not the gateway token: it is
required by the schema but never used as an ingress credential.

Inbound A2A runs with the routed agent's normal tools and permissions. LiteLLM's A2A access control is default-open unless the calling key or team has an explicit `object_permission.agents` grant.

## Disk hygiene

The state volume holds every conversation, workspace and database, so the `init`
container bounds each class of data that grows unattended, on every start (pod
restart or image bump). Nothing still in use disappears; kopia already excludes
these paths (`app/kopiaignore.yaml`).

| Path | Rule |
|---|---|
| `~/.openclaw.update-captures/doctor-*` | newest kept plus any capture with a file modified in the last 3 days — `doctor` writes one ~280M recovery capture per repair run |
| `~/.openclaw/state/*doctor-cron-*.bak` | newest plus 3 days — the daily cron leaves one full copy of `openclaw.sqlite` |
| `~/.openclaw/state/*pre-startup-migration-*.bak` | newest plus 3 days — one copy per startup migration |
| `~/.openclaw/agents/*/agent/*.pre-startup-migration-*.bak` | newest per agent plus 7 days |
| `~/.openclaw/agents/**/*.sqlite.bak-*` | files older than 30 days (legacy one-off snapshots) |
| `~/.npm/_cacache` | dropped whole once it exceeds 500M |
| `~/.npm/_logs` | files older than 7 days |
| `~/.openclaw/tmp/plugin-captures/*` | entries older than 7 days |

Capture age is measured on the files inside, not the directory's own mtime: a
capture stops moving once `doctor` is done writing, so a directory that merely
*looks* old can still be the newest rollback point. A failed scan keeps the
capture rather than deleting it. Unknown `state/*.bak` classes are never touched
— the prune only knows the two names it ships.

On 2026-11-23 the volume sat at 54% (10.9G of 20G): 13 state copies (888M for a
77M database, one more per restart, none ever pruned) and ~2G of captures.

The semantics are covered by fixtures in
[`kubernetes/tests/test-retention-init.sh`](../../../tests/test-retention-init.sh)
(`just kube test-init`), which runs the shipped script in the same image as the
pod.

## Private stores

OpenClaw keeps its local credential stores on the state volume and refuses to
read them when their modes drift:

| Path | Required | Owner |
|---|---|---|
| `~/.openclaw/client/` | `0700` | uid 1000 |
| `~/.openclaw/client/credentials.sqlite` | `0600` | uid 1000 |
| `~/.openclaw/credentials/` | `0700` | uid 1000 |

`client/credentials.sqlite` holds the device identities (private keys), the
per-device/role bearer tokens and the native exec socket token, so the gateway
reads it before **every** command it runs. When the directory is not private it
fails with `Client credential directory is unsafe.` — a message that names
neither the path nor a fix, and that a `chmod` on `~/.config/op` cannot address.

Two properties make this regress silently:

- the store is authorized with `mode & 0o077`, so a directory recreated at
  runtime inherits the parent's setgid/gid and comes back `2755`;
- the gateway only restores private modes at startup, and its repair refuses
  foreign owners and world-access bits.

Hence: no `fsGroup` on the pod (kubelet's recursive ownership pass sets group
rwx on the whole volume — upstream names an `fsGroup` volume remount as the
widening mechanism), and the `init` container normalizes `client/` and its
database on every boot, which is the only step that always runs before the
gateway.

That init pass is also what repairs a restored volume: a kopiur restore lays
down a staging copy produced by a mover that runs with its own `fsGroup`, so the
restored tree can come back group-writable. The invariant is "restore, then
start the pod" — the init normalizes every private path before the gateway can
read it, which only holds as long as this list stays in sync with the paths the
app treats as private.

## Related

- Flux `Kustomization`: `ks.yaml` (namespace `ai`, `interval: 1h`, `postBuild`
  `APP=mainclaw`).
- PVC backups: the `kopiur/backup` component (`KOPIUR_CAPACITY=20Gi`).
