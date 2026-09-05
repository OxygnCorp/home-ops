# mainclaw "Harvey" Legal Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `legal` agent ("Harvey", droit français, factuel + sources officielles) to the mainclaw OpenClaw instance, bound to the Discord channel referenced by the 1Password-injected `DISCORD_LEGAL_CHANNEL_ID` (1Password item `mainclaw`).

**Architecture:** Pure GitOps config change — the agent is appended to `openclaw.json` (agent definition, binding, channel entry, execApprovals filter) and `DISCORD_LEGAL_CHANNEL_ID` is added to the `mainclaw` ExternalSecret. external-secrets renders both secrets; the stakater reloader restarts the pod. No PVC, HelmRelease, or kustomization changes.

**Tech Stack:** Flux GitOps, external-secrets (1Password ClusterSecretStore `onepassword`), kustomize `configMapGenerator`, openclaw gateway config schema (2026.9.1), `jq` validation, `flate` pre-push guard.

**Spec:** `docs/superpowers/specs/2026-09-05-mainclaw-legal-agent-design.md` (committed on this branch).

## Global Constraints

- Branch `feat/mainclaw-legal-agent` already exists with the design spec committed (HEAD = `e9d5c4e80`). Do all work there. **Never commit to main.**
- `openclaw.json` is strict-schema-checked by openclaw 2026.9.1 on boot — use **only** keys already present on existing agents (verified in the spec). No new keys invented.
- No secrets in Git: the channel id (the `DISCORD_LEGAL_CHANNEL_ID` value, 1Password item `mainclaw`) is **never** written literally. It lives in the 1Password item `mainclaw` (user added it, field `DISCORD_LEGAL_CHANNEL_ID`) and is referenced in configs as `{{ .DISCORD_LEGAL_CHANNEL_ID }}`.
- Model refs `litellm/MiniMax-M3`, `litellm/go-qwen3.8-max`, `litellm/zai-glm-5.3` are all in `agents.defaults.modelPolicy.allow` (openclaw.json:124-141) — do not modify model catalog, aliases, or modelPolicy.
- JSON style: 2-space indent; mimic the neighboring `lycos` block ordering for agent objects and `(enabled, requireMention, skills, systemPrompt)` for channel entries. Every edit must keep the file valid JSON (`jq -e .` must pass).
- Commit message style: conventional commits with `ai/mainclaw` scope (see `git log --oneline`).

---

### Task 1: Agent definition in `openclaw.json`

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json:544-546` (append agent to `agents.list`), `:667-675` (execApprovals agentFilter)

**Interfaces:**
- Consumes: existing agent-block schema (copy of `lycos` fields, no `heartbeat`, no per-agent `exec`).
- Produces: agent `legal` present in `agents.list`; `"legal"` present in `channels.discord.execApprovals.agentFilter`. Tasks 2 relies on agent id `legal`.

- [ ] **Step 1: Append the agent block to `agents.list`**

In `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, replace (end of the `lycos` block, lines 543-547):

```json
          "exec": {
            "security": "full"
          }
        },
        "thinkingDefault": "medium"
      }
    ]
  },
```

with:

```json
          "exec": {
            "security": "full"
          }
        },
        "thinkingDefault": "medium"
      },
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
          "mentionPatterns": [
            "@harvey",
            "@legal"
          ]
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
    ]
  },
```

(No `heartbeat` block; no per-agent `exec` block — Harvey inherits the instance-global
`tools.exec: {security: "allowlist", ask: "on-miss"}` from openclaw.json:1472-1476.)

- [ ] **Step 2: Verify the agent parses**

Run: `jq -e '.agents.list[] | select(.id=="legal") | .name' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `"Harvey"` (no JSON parse error).

- [ ] **Step 3: Add `"legal"` to `execApprovals.agentFilter`**

Replace (lines 667-675):

```json
        "agentFilter": [
          "main",
          "family",
          "coach",
          "finance",
          "shopping",
          "media",
          "lycos"
        ],
```

with:

```json
        "agentFilter": [
          "main",
          "family",
          "coach",
          "finance",
          "shopping",
          "media",
          "lycos",
          "legal"
        ],
```

- [ ] **Step 4: Verify the filter**

Run: `jq -e '.channels.discord.execApprovals.agentFilter | index("legal")' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `7` (array index; any non-null number is fine).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): add Harvey legal agent definition"
```

---

### Task 2: Discord routing — binding + channel entry

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json:636-637` (bindings array), `:759` (guild channels map)

**Interfaces:**
- Consumes: agent id `legal` from Task 1; env placeholders `{{ .DISCORD_LEGAL_CHANNEL_ID }}` (rendered by external-secrets, field added to 1Password by the user) and `{{ .DISCORD_GUILD_ID }}` (already present).
- Produces: binding channel→`legal`; guild channel entry keyed `{{ .DISCORD_LEGAL_CHANNEL_ID }}`.

- [ ] **Step 1: Append the binding**

Replace (end of bindings array, lines 626-637):

```json
    {
      "agentId": "lycos",
      "match": {
        "channel": "discord",
        "peer": {
          "kind": "channel",
          "id": "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        },
        "guildId": "{{ .DISCORD_GUILD_ID }}"
      }
    }
  ],
```

with:

```json
    {
      "agentId": "lycos",
      "match": {
        "channel": "discord",
        "peer": {
          "kind": "channel",
          "id": "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        },
        "guildId": "{{ .DISCORD_GUILD_ID }}"
      }
    },
    {
      "agentId": "legal",
      "match": {
        "channel": "discord",
        "peer": {
          "kind": "channel",
          "id": "{{ .DISCORD_LEGAL_CHANNEL_ID }}"
        },
        "guildId": "{{ .DISCORD_GUILD_ID }}"
      }
    }
  ],
```

- [ ] **Step 2: Verify the binding**

Run: `jq -e '.bindings[] | select(.agentId=="legal") | .match.peer.id' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `"{{ .DISCORD_LEGAL_CHANNEL_ID }}"`.

- [ ] **Step 3: Add the guild channel entry**

Replace (lycos channel entry, lines 751-759):

```json
            "{{ .DISCORD_LYCOS_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es l'assistant recherche. Sois précis, indique tes sources, fait des tableaux comparatifs."
            },
```

with (lycos entry unchanged, then the new entry appended):

```json
            "{{ .DISCORD_LYCOS_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es l'assistant recherche. Sois précis, indique tes sources, fait des tableaux comparatifs."
            },
            "{{ .DISCORD_LEGAL_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es Harvey, mon assistant juridique pour le droit français. Sois factuel, précis et intelligible."
            },
```

(The detailed legal charter — France-only jurisdiction, official-source citations
[legifrance.gouv.fr, service-public.fr], refusal on insufficient inputs, non-lawyer
disclaimer — is deliberately NOT here. It will live in Harvey's workspace `.md` files,
which the user will prompt Harvey to write after first boot.)

- [ ] **Step 4: Verify the channel entry**

Run: `jq -r '.channels.discord.guilds["{{ .DISCORD_GUILD_ID }}"].channels["{{ .DISCORD_LEGAL_CHANNEL_ID }}"].systemPrompt' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `Tu es Harvey, mon assistant juridique pour le droit français. Sois factuel, précis et intelligible.`

- [ ] **Step 5: Full-file JSON sanity**

Run: `jq -e . kubernetes/apps/ai/mainclaw/app/resources/openclaw.json > /dev/null && echo OK`
Expected output: `OK`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): route legal Discord channel to Harvey"
```

---

### Task 3: ExternalSecret channel id + full pre-push validation

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml:29-30`

**Interfaces:**
- Consumes: 1Password item `mainclaw` field `DISCORD_LEGAL_CHANNEL_ID` (user added it pre-implementation).
- Produces: env key `DISCORD_LEGAL_CHANNEL_ID` in secret `mainclaw-secret`, consumed by the pod env (`envFrom` in `helmrelease.yaml`) and by the `mainclaw-config` rendered secret (via `dataFrom: extract: key: mainclaw`, no edit needed there).

- [ ] **Step 1: Add the template line**

In `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml`, replace:

```yaml
        DISCORD_LYCOS_CHANNEL_ID: "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        DISCORD_CLAW_PROJECT_FORUM: "{{ .DISCORD_CLAW_PROJECT_FORUM }}"
```

with:

```yaml
        DISCORD_LYCOS_CHANNEL_ID: "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        DISCORD_LEGAL_CHANNEL_ID: "{{ .DISCORD_LEGAL_CHANNEL_ID }}"
        DISCORD_CLAW_PROJECT_FORUM: "{{ .DISCORD_CLAW_PROJECT_FORUM }}"
```

- [ ] **Step 2: Run flate (full pre-push guard)**

Run: `mise exec -- flate test ks --path ./kubernetes/apps`
Expected: all Kustomizations pass (30-60s). If `flate test hr` is available, also run
`mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw` — expect PASS.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/externalsecret.yaml
git commit -m "feat(ai/mainclaw): wire DISCORD_LEGAL_CHANNEL_ID into mainclaw secret"
```

---

### Task 4: Push + PR

**Files:**
- None (git operations only). Branch: `feat/mainclaw-legal-agent` (3 commits ahead of main + spec commit).

**Interfaces:**
- Consumes: all commits from Tasks 1-3.
- Produces: PR URL for user review; konflate will post rendered Flux diffs as a PR comment.

- [ ] **Step 1: Push the branch**

Run: `git push -u origin feat/mainclaw-legal-agent`
Expected: branch created on origin, no rejection.

- [ ] **Step 2: Open the PR**

Run:

```bash
gh pr create --title "feat(ai/mainclaw): add Harvey legal agent" --body "## Summary
- New agent \`legal\` (\"Harvey\") in mainclaw \`openclaw.json\`: MiniMax-M3 primary (fallbacks go-qwen3.8-max, zai-glm-5.3), workspace \`workspace-legal\`, memory + wiki tools, no heartbeat, no per-agent exec (inherits global allowlist exec policy)
- Discord binding + guild channel entry for \`DISCORD_LEGAL_CHANNEL_ID\` (channel/guild ids via \`DISCORD_LEGAL_CHANNEL_ID\`/\`DISCORD_GUILD_ID\` (1Password)), skills search/docs, one-line systemPrompt (charter to be written by Harvey itself in workspace .md files post-boot)
- \`DISCORD_LEGAL_CHANNEL_ID\` added to the \`mainclaw\` ExternalSecret (1Password field already present)

## Validation
- jq checks on agents.list / bindings / guild channels / execApprovals.agentFilter
- flate test ks (full repo) PASS

## Post-merge checks
- \`kubectl get externalsecret mainclaw -n ai\` → SecretSynced
- Pod restarted by stakater reloader, openclaw boots clean (no schema rejection)
- Discord round-trip in the legal channel; \`workspace-legal\` created on PVC

Design: docs/superpowers/specs/2026-09-05-mainclaw-legal-agent-design.md"
```

Expected: PR URL printed.

- [ ] **Step 3: Report the PR URL to the user** (do not merge unless asked).

---

### Task 5 (post-merge): Deploy verification — only after the user merges

**Files:**
- None (read-only cluster checks).

- [ ] **Step 1: Secret rendered**

Run: `kubectl get externalsecret mainclaw -n ai`
Expected: `SecretSynced` (refresh 1h; reconcile if needed: `flux reconcile helmrelease` is not required — the reloader watches the secret).

Run: `kubectl get externalsecret mainclaw-config -n ai`
Expected: `SecretSynced` (this secret carries the rendered `openclaw.json`; a missing 1Password field surfaces here first).

Run: `kubectl get secret mainclaw-secret -n ai -o jsonpath='{.data.DISCORD_LEGAL_CHANNEL_ID}' | base64 -d`
Expected: the `DISCORD_LEGAL_CHANNEL_ID` value from the 1Password item `mainclaw`.

- [ ] **Step 2: Pod restarted clean**

Run: `kubectl get pods -n ai -l app.kubernetes.io/name=mainclaw -w` (or check pod age) and
`kubectl logs -n ai <pod> | grep -iE 'legal|harvey|error' | head -20`
Expected: new pod age, no config-load/schema errors, agent `legal` registered.

- [ ] **Step 3: Discord round-trip**

User posts in the legal Discord channel (`DISCORD_LEGAL_CHANNEL_ID`); Harvey replies. Then Harvey can be prompted to write
its charter files (`.md`) in `/home/node/.openclaw/workspace-legal` (user-driven step).
