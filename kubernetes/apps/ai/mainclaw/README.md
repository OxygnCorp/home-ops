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

## Related

- Flux `Kustomization`: `ks.yaml` (namespace `ai`, `interval: 1h`, `postBuild`
  `APP=mainclaw`).
- PVC backups: the `kopiur/backup` component (`KOPIUR_CAPACITY=20Gi`).
