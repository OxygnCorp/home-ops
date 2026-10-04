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

## Related

- Flux `Kustomization`: `ks.yaml` (namespace `ai`, `interval: 1h`,
  `postBuild` `APP=devclaw`).
- PVC backups: the `kopiur/backup` component (`KOPIUR_CAPACITY=10Gi`).
