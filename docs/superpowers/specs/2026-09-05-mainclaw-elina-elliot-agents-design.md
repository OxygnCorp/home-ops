# mainclaw: agents personnels "Elina" et "Elliot"

- **Date:** 2026-09-05
- **Status:** Approved design (pre-implementation)
- **Scope:** `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml`
- **Base branch:** stacked on `feat/mainclaw-legal-agent` (same file, same touchpoints)

## Problem

Matt wants two personal agents on the mainclaw instance, one per child:

| Child | Agent id | Display name |
|---|---|---|
| Elina | `elina` | Elina |
| Elliot | `elliot` | Elliot |

Initially named `lily` / `tractor`, renamed to the children's first names at user request.

**Purpose (parents-only for now):** Matt and Agnès will use these agents to

- track the children's learning progress,
- propose age-appropriate games and activities,
- note and follow their interests over time.

The children have **no access today** (Discord `allowFrom` / guild `users` stay
Matt + Agnès only). Kid-facing access is future work.

Fixed requirements (user-confirmed):

| Requirement | Value |
|---|---|
| Agent ids | `elina`, `elliot` |
| Identity | Name only — **no emoji yet**, user will pick icons later |
| Behavior | **No heartbeat — purely reactive** |
| Model | `litellm/MiniMax-M3` via **defaults inheritance** (no per-agent `model` key) |
| System prompts | Minimal one-liners; user will personalize the agents post-boot |
| Channel secrets | `DISCORD_ELINA_CHANNEL_ID`, `DISCORD_ELLIOT_CHANNEL_ID` — **already added** to the 1Password item `mainclaw` by the user |

Design decisions from brainstorming:

- **Full-pattern integration** (the "family/coach" shape), not a minimal cut:
  active-memory context injection, inter-agent delegation, and exec-approval routing
  are all wanted here — these agents accumulate long-term knowledge about the kids,
  and main/nova should be able to delegate to them.
- **Model inheritance over override:** `agents.defaults.model` is already
  `litellm/MiniMax-M3` with fallbacks `go-minimax-m3` → `dsv4f`. Omitting the
  per-agent `model` key yields exactly the user-requested model with less config.
- **memini memory is automatic:** the instance runs `memini` with
  `namespace_per_agent: true`, so each agent gets an isolated memory namespace for
  free — the core mechanism for the "suivi dans la durée" goal.
- **No per-agent `exec` block** (legal-agent precedent, same day): the agents
  inherit the instance-global restrictive exec policy
  (`security: "allowlist"`, `ask: "on-miss"`) instead of the `security: "full"`
  shell that family-style agents grant themselves. These agents will eventually be
  child-facing; a free shell is the one capability that would need re-thinking then.
  Note: this deliberately tightens the "comme family" shorthand agreed verbally —
  flag it at spec review.
- **Workspace convention:** `workspace-elina` / `workspace-elliot`, sibling dirs of
  the shared PVC mount (`/home/node/.openclaw`), like every other agent.

## Changes

### 1. `openclaw.json` — `agents.list[]` (append after `legal`)

Only schema keys already proven by existing agents (openclaw 2026.9.1 rejects
deprecated keys — cf. 2026-09-04 litellm refresh incident):

```json
{
  "id": "elina",
  "name": "Elina",
  "workspace": "/home/node/.openclaw/workspace-elina",
  "agentDir": "/home/node/.openclaw/agents/elina/agent",
  "identity": { "name": "Elina" },
  "groupChat": { "mentionPatterns": ["@elina"] },
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
  }
}
```

```json
{
  "id": "elliot",
  "name": "Elliot",
  "workspace": "/home/node/.openclaw/workspace-elliot",
  "agentDir": "/home/node/.openclaw/agents/elliot/agent",
  "identity": { "name": "Elliot" },
  "groupChat": { "mentionPatterns": ["@elliot"] },
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
  }
}
```

- **No `heartbeat`** block — reactive only.
- **No `model`** key — inherits defaults (`litellm/MiniMax-M3`, fallbacks
  `go-minimax-m3` → `dsv4f`).
- **No `emoji`** in `identity` — added later by the user.
- Wiki tools (`memory-wiki` plugin) let the parents maintain structured learning
  notes / interest maps next to conversational memory (memini).

### 2. `openclaw.json` — `bindings[]` (append after legal)

```json
{
  "agentId": "elina",
  "match": {
    "channel": "discord",
    "peer": { "kind": "channel", "id": "{{ .DISCORD_ELINA_CHANNEL_ID }}" },
    "guildId": "{{ .DISCORD_GUILD_ID }}"
  }
}
```

```json
{
  "agentId": "elliot",
  "match": {
    "channel": "discord",
    "peer": { "kind": "channel", "id": "{{ .DISCORD_ELLIOT_CHANNEL_ID }}" },
    "guildId": "{{ .DISCORD_GUILD_ID }}"
  }
}
```

### 3. `openclaw.json` — `channels.discord.guilds.<GUILD>.channels` (insert after legal, before the forums)

```json
"{{ .DISCORD_ELINA_CHANNEL_ID }}": {
  "enabled": true,
  "requireMention": false,
  "skills": ["search", "docs"],
  "systemPrompt": "Tu es Elina, l'assistante d'Elina. Matt et Agnès te consultent pour suivre ses apprentissages, proposer des jeux adaptés et noter ses centres d'intérêt. Sois chaleureuse, créative et garde une trace de ce qui fonctionne."
}
```

```json
"{{ .DISCORD_ELLIOT_CHANNEL_ID }}": {
  "enabled": true,
  "requireMention": false,
  "skills": ["search", "docs"],
  "systemPrompt": "Tu es Elliot, l'assistant d'Elliot. Matt et Agnès te consultent pour suivre ses apprentissages, proposer des jeux adaptés et noter ses centres d'intérêt. Sois chaleureux, créatif et garde une trace de ce qui fonctionne."
}
```

One-line identity + purpose, matching the other agent channels. The user will
rewrite these when personalizing the agents post-boot.

### 4. `openclaw.json` — `channels.discord.execApprovals.agentFilter` (add `"elina"`, `"elliot"` after `"legal"`)

The agents inherit `ask: on-miss` exec semantics; the filter routes any
allowlist-miss exec approval to the existing Discord approval flow (approvers:
Matt, Agnès) instead of an unroutable ask.

### 5. `openclaw.json` — `plugins.entries.active-memory.config.agents` (add `"elina"`, `"elliot"`)

Active-memory injects recent relevant memories into context — useful for the
parents' ongoing tracking use case. These are the first agents added to this list
after the original eight; `legal` intentionally stayed out (approach A), but the
approved design for elina/elliot includes it.

### 6. `openclaw.json` — `tools.agentToAgent.allow` (add `"elina"`, `"elliot"`)

Allows main/nova (and the others already in the list) to delegate to the two new
agents — e.g. "demande à Elina ce qu'on a proposé la semaine dernière".

### 7. `externalsecret.yaml` — `mainclaw` ExternalSecret `template.data` (add after `DISCORD_LEGAL_CHANNEL_ID`)

```yaml
DISCORD_ELINA_CHANNEL_ID: "{{ .DISCORD_ELINA_CHANNEL_ID }}"
DISCORD_ELLIOT_CHANNEL_ID: "{{ .DISCORD_ELLIOT_CHANNEL_ID }}"
```

The `mainclaw-config` ExternalSecret needs no change (its `dataFrom: extract:
key: mainclaw` already picks up the new 1Password fields, and `templateFrom`
re-renders `openclaw.json` against the merged secret on its 1-minute refresh).

### Not changed

- `channels.discord.allowFrom` and guild `users` — Matt + Agnès only; the children
  get no access in this change.
- No `model`, `heartbeat`, or per-agent `exec` blocks — inheritance as described.
- PVC, HelmRelease, kustomization, ks.yaml — untouched (single shared PVC already
  mounted at `/home/node`; workspace dirs are created by openclaw at first run).
- No workspace bootstrap files in Git — workspace `.md` files live on the PVC
  (existing convention); the user will drive their creation after first boot.

## Deployment order

1. PR opened from `feat/mainclaw-elina-elliot` (stacked on the legal branch);
   user confirms 1Password fields `DISCORD_ELINA_CHANNEL_ID` /
   `DISCORD_ELLIOT_CHANNEL_ID` are on the `mainclaw` item (**already done** at
   design time), and the two Discord channels exist.
2. Legal PR merges first, this PR rebases clean (pure appends at the same
   anchors), then merges → Flux reconciles → external-secrets refreshes
   `mainclaw-secret` (1h) and `mainclaw-config` (1m) → stakater reloader restarts
   the pod on both secrets.
3. Verify pod restarts clean (no config-load error — schema is strict on 2026.9.1).
4. Discord round-trip in both new channels; confirm the agents answer and
   `workspace-elina` / `workspace-elliot` + `agents/elina|elliot/agent` appear on
   the PVC.

## Validation

1. `jq` sanity on the rendered configmap source:
   `jq -e '.agents.list[] | select(.id=="elina" or .id=="elliot")'` plus greps for
   the two channel env vars in bindings / guild channels / agentFilter /
   active-memory / agentToAgent (pattern from the litellm refresh).
2. `mise exec -- flate test ks --path ./kubernetes/apps` (pre-push guard).
3. Post-deploy: `kubectl get secret mainclaw-secret -o jsonpath` shows the
   rendered channel ids; mainclaw pod logs show agents `elina` and `elliot`
   registered; Discord round-trip works in both channels.

## Risks & rollback

- **Missing 1Password field** would break the `mainclaw` ExternalSecret render —
  mitigated: user added both fields before implementation; verify `kubectl get
  externalsecret mainclaw` is `SecretSynced` after merge.
- **Stacked-branch risk**: if the legal PR changes shape, rebase may need manual
  conflict resolution in `openclaw.json` (pure appends here, low risk).
- **`identity` without `emoji`** is the only shape not proven by an existing
  agent (every current agent sets an emoji). Emoji is expected to be optional
  (`identity` itself is optional in `agents.defaults`); the post-deploy pod-log
  check catches a schema rejection either way, and the user adds icons soon.
- **MiniMax-M3 quota**: two more default-model agents add idle load only (no
  heartbeat, reactive usage by two adults) — negligible.
- Rollback = `git revert` of the PR; Flux re-renders the previous secret within
  one reconcile cycle and the reloader restarts the pod.

## Out of scope (future work)

- Child access to Discord / their own agent (allowFrom, per-user policy, exec
  sandboxing review).
- Emoji / icons for the two agents (user will choose).
- Personalized system prompts and workspace charter `.md` files (user-driven,
  post-first-boot).
- Heartbeat-driven reminders (activity ideas, follow-ups) if wanted later.
