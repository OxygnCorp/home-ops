# mainclaw: "Harvey" legal agent

- **Date:** 2026-09-05
- **Status:** Approved design (pre-implementation)
- **Scope:** `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml`

## Problem

The user (Matt) wants a legal assistant on the mainclaw instance to help with:

- Disputes / litigation tracking (contentieux)
- Contract analysis: insurance, mortgage (prêt immobilier), prévoyance
- Administrative procedures guidance (démarches administratives)
- A global view of current protection coverage and its blind spots

Fixed requirements (user-confirmed):

| Requirement | Value |
|---|---|
| Agent id | `legal` |
| Name | Harvey |
| Jurisdiction | **France only** |
| Behavior | Strictly factual, cites official sources, refuses to answer when inputs are insufficient |
| Tone | Crisp and precise, but intelligible |
| Discord channel | `DISCORD_LEGAL_CHANNEL_ID` value (guild `DISCORD_GUILD_ID`) — 1Password item `mainclaw` |
| Channel secret | `DISCORD_LEGAL_CHANNEL_ID` — **already added** to the 1Password item `mainclaw` by the user |

Design decisions from brainstorming:

- **Approach A** (reactive agent, restricted tooling) — no inter-agent delegation, no dedicated
  legal-source MCP. Both are additive later.
- **No heartbeat** — Harvey only speaks when asked.
- Model: **`litellm/MiniMax-M3`** primary (1M context for full contracts, reasoning-capable,
  volume plan), fallbacks `go-qwen3.8-max` → `zai-glm-5.3` (both cross-plan).
- Workspace: `/home/node/.openclaw/workspace-legal` (sibling convention, like `workspace-family`,
  `workspace-lycos`) — **not** the `/workspace/legal` subdir originally suggested, which would
  have nested inside Claw's own workspace.
- **System prompt stays minimal.** The detailed legal charter (France-only, official-source
  citations, refusal policy, tone, non-lawyer disclaimer) will live in the agent's workspace
  `.md` files (AGENTS.md etc.), which the user will prompt Harvey to write after first boot.
  The inline channel `systemPrompt` is a one-line identity only, matching the other 11 channels.

## Changes

### 1. `openclaw.json` — `agents.list[]` (append after `lycos`)

Only schema keys already proven by existing agents (openclaw 2026.9.1 rejects deprecated keys —
cf. 2026-09-04 litellm refresh incident):

```json
{
  "id": "legal",
  "name": "Harvey",
  "workspace": "/home/node/.openclaw/workspace-legal",
  "agentDir": "/home/node/.openclaw/agents/legal/agent",
  "model": {
    "primary": "litellm/MiniMax-M3",
    "fallbacks": ["litellm/go-qwen3.8-max", "litellm/zai-glm-5.3"]
  },
  "identity": {
    "name": "Harvey",
    "emoji": "⚖️"
  },
  "groupChat": {
    "mentionPatterns": ["@harvey", "@legal"]
  },
  "tools": {
    "profile": "full",
    "alsoAllow": [
      "memory_recall",
      "memory_list",
      "memory_remember",
      "message",
      "agents_list",
      "wiki_status",
      "wiki_search",
      "wiki_lint",
      "wiki_apply",
      "wiki_get"
    ]
  },
  "thinkingDefault": "high"
}
```

- **No `heartbeat`** block — reactive only.
- **No per-agent `exec` block** — inherits the instance-global restrictive policy
  (`tools.exec: {security: "allowlist", ask: "on-miss"}`) instead of the `security: full`
  shell the other agents grant themselves. A legal agent has no legitimate need for a free
  shell; `fs` stays workspace-scoped by the global `fs.workspaceOnly: true`.
- Wiki tools (`memory-wiki` plugin) let Harvey maintain the structured coverage inventory /
  blind-spot map the user asked for, next to conversational memory (memini).

### 2. `openclaw.json` — `bindings[]` (append)

```json
{
  "agentId": "legal",
  "match": {
    "channel": "discord",
    "peer": { "kind": "channel", "id": "{{ .DISCORD_LEGAL_CHANNEL_ID }}" },
    "guildId": "{{ .DISCORD_GUILD_ID }}"
  }
}
```

### 3. `openclaw.json` — `channels.discord.guilds.<GUILD>.channels` (append after lycos)

```json
"{{ .DISCORD_LEGAL_CHANNEL_ID }}": {
  "enabled": true,
  "requireMention": false,
  "skills": ["search", "docs"],
  "systemPrompt": "Tu es Harvey, mon assistant juridique pour le droit français. Sois factuel, précis et intelligible."
}
```

The `search` skill + globally enabled `web.search` (minimax provider) and `web.fetch` give
Harvey the official-source research channel (legifrance.gouv.fr, service-public.fr, etc.).
Charter enforcement happens in the workspace `.md` files, not here.

### 4. `openclaw.json` — `channels.discord.execApprovals.agentFilter` (add `"legal"`)

Harvey inherits `ask: on-miss` exec semantics; adding him to the agent filter routes any
allowlist-miss exec approval to the existing Discord approval flow (approvers: Matt, Agnes)
instead of an unroutable ask.

### 5. `externalsecret.yaml` — `mainclaw` ExternalSecret `template.data` (add)

```yaml
DISCORD_LEGAL_CHANNEL_ID: "{{ .DISCORD_LEGAL_CHANNEL_ID }}"
```

The `mainclaw-config` ExternalSecret needs no change (its `dataFrom: extract: key: mainclaw`
already picks up the new 1Password field, and `templateFrom` re-renders `openclaw.json`
against the merged secret on its 1-minute refresh).

### Not changed

- `tools.agentToAgent.allow` — `legal` not added (no delegation in approach A).
- PVC, HelmRelease, kustomization, ks.yaml — untouched (single shared PVC already mounted at
  `/home/node`; workspace dirs are created by openclaw at first run).
- No workspace bootstrap files in Git — workspace `.md` files live on the PVC (existing
  convention); the user will drive their creation by prompting Harvey after first boot.

## Deployment order

1. PR opened from a feature branch; user confirms 1Password field `DISCORD_LEGAL_CHANNEL_ID`
   is on the `mainclaw` item (**already done** at design time).
2. Merge → Flux reconciles → external-secrets refreshes `mainclaw-secret` (1h) and
   `mainclaw-config` (1m) → stakater reloader restarts the pod on both secrets.
3. Check `kubectl get externalsecret mainclaw-config -n ai` is `SecretSynced`, then verify the
   pod restarts clean (no config-load error — schema is strict on 2026.9.1).
4. Discord round-trip in the legal Discord channel; confirm Harvey answers and
   `workspace-legal` + `agents/legal/agent` appear on the PVC.

## Validation

1. `jq` sanity on the rendered configmap source: `jq -e '.agents.list[] | select(.id=="legal")'`
   and bindings/channels greps on `resources/openclaw.json` (pattern from the litellm refresh).
2. `mise exec -- flate test ks --path ./kubernetes/apps` (pre-push guard).
3. Post-deploy: `kubectl get secret mainclaw-secret -o jsonpath` shows the rendered channel id;
   mainclaw pod logs show agent `legal` registered; Discord round-trip works.

## Risks & rollback

- **Missing 1Password field** would break the `mainclaw` ExternalSecret render — mitigated:
  user added it before implementation; verify `kubectl get externalsecret mainclaw` is
  `SecretSynced` after merge.
- **Fallback quota note**: `go-qwen3.8-max` (810/mo, lycos primary) is fallback-only for
  Harvey — negligible added load; `zai-glm-5.3` also serves devclaw FB1 only.
- Rollback = `git revert` of the PR; Flux re-renders the previous secret within one
  reconcile cycle and the reloader restarts the pod.

## Out of scope (future work)

- Approach B: inter-agent delegation (`subagents.allowAgents` / `agentToAgent.allow`).
- Approach C: dedicated Légifrance/PISTE MCP server via toolhive for primary-source lookups.
- Heartbeat-driven periodic coverage review / deadline reminders.
- Writing Harvey's workspace charter `.md` files (user-driven, post-first-boot).
