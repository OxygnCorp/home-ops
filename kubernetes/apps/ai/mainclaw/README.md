# mainclaw

The personal OpenClaw gateway: one Discord bot (`@claw-assistant`) fronting
several long-lived agents, each with its own workspace and sqlite database on a
20Gi PVC. Models go through litellm, cluster access through the litellm MCP
gateway. The DevOps-facing twin lives in [`../devclaw`](../devclaw).

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
