# mainclaw "Elina" + "Elliot" Agents Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two personal agents to the mainclaw OpenClaw instance — `elina` and `elliot` — bound to their own Discord channels via 1Password-injected `DISCORD_ELINA_CHANNEL_ID` / `DISCORD_ELLIOT_CHANNEL_ID`, used by Matt and Agnès to track the children's learning, propose games, and note their interests. The children have no access.

**Architecture:** Pure GitOps config change, identical in shape to the legal-agent change stacked underneath this branch. Each agent is appended to `openclaw.json` in six places (agent definition, binding, guild channel entry, execApprovals filter, active-memory agents, agentToAgent allow) and two env keys are added to the `mainclaw` ExternalSecret. external-secrets renders both secrets; the stakater reloader restarts the pod.

**Tech Stack:** Flux GitOps, external-secrets (1Password ClusterSecretStore `onepassword`), kustomize `configMapGenerator`, openclaw gateway config schema (2026.9.1), `jq` validation, `flate` pre-push guard.

**Spec:** `docs/superpowers/specs/2026-09-05-mainclaw-elina-elliot-agents-design.md` (committed on this branch).

## Global Constraints

- Branch `feat/mainclaw-elina-elliot` already exists, **stacked on the rebuilt `feat/mainclaw-legal-agent` branch (head `c7fb75b4e`)** — the original legal docs commits were redacted and rebuilt in a worktree; the branch was rebased onto `c7fb75b4e` (docs commits now `563a1463d` spec + `37269d566` plan). Do all work there. **Never commit to main.**
- `openclaw.json` is strict-schema-checked by openclaw 2026.9.1 on boot — use **only** keys already present on existing agents (verified in the spec). No new keys invented.
- **No `model`, `heartbeat`, or per-agent `exec` keys** on the two new agents: model inherits `agents.defaults` (`litellm/MiniMax-M3`, fallbacks `go-minimax-m3` → `dsv4f` — user-confirmed), no proactive behavior, and exec inherits the instance-global `tools.exec: {security: "allowlist", ask: "on-miss"}` (openclaw.json:1529-1533).
- **No emoji** in `identity` — name only (user picks icons later).
- No secrets in Git: channel ids are **never** written literally. They live in the 1Password item `mainclaw` (user already added fields `DISCORD_ELINA_CHANNEL_ID` and `DISCORD_ELLIOT_CHANNEL_ID`) and are referenced in configs as `{{ .DISCORD_ELINA_CHANNEL_ID }}` / `{{ .DISCORD_ELLIOT_CHANNEL_ID }}`.
- Do not modify the model catalog, aliases, or `modelPolicy` — `litellm/MiniMax-M3` is already allowed (openclaw.json:126).
- JSON style: 2-space indent; mimic the neighboring `legal` block key ordering for agent objects (`id, name, workspace, agentDir, identity, groupChat, tools`) and `(enabled, requireMention, skills, systemPrompt)` for channel entries. Every edit must keep the file valid JSON (`jq -e .` must pass).
- Commit message style: conventional commits with `ai/mainclaw` scope (see `git log --oneline`).

---

### Task 1: Agent definitions in `openclaw.json`

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json:565-583` (append to `agents.list`), `:714-723` (execApprovals agentFilter)

**Interfaces:**
- Consumes: existing agent-block schema (copy of `legal` fields minus `model`/`thinkingDefault`, no `heartbeat`, no per-agent `exec`, no `emoji`).
- Produces: agents `elina` and `elliot` present in `agents.list`; both ids present in `channels.discord.execApprovals.agentFilter`. Tasks 2-3 rely on agent ids `elina` / `elliot`.

- [ ] **Step 1: Append both agent blocks to `agents.list`**

In `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, replace (end of the `legal` block, lines 565-583):

```json
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

with:

```json
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
      },
      {
        "id": "elina",
        "name": "Elina",
        "workspace": "/home/node/.openclaw/workspace-elina",
        "agentDir": "/home/node/.openclaw/agents/elina/agent",
        "identity": {
          "name": "Elina"
        },
        "groupChat": {
          "mentionPatterns": [
            "@elina"
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
        }
      },
      {
        "id": "elliot",
        "name": "Elliot",
        "workspace": "/home/node/.openclaw/workspace-elliot",
        "agentDir": "/home/node/.openclaw/agents/elliot/agent",
        "identity": {
          "name": "Elliot"
        },
        "groupChat": {
          "mentionPatterns": [
            "@elliot"
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
        }
      }
    ]
  },
```

(No `heartbeat` — reactive only. No `model` — inherits `agents.defaults` =
`litellm/MiniMax-M3` + fallbacks `go-minimax-m3` → `dsv4f`. No per-agent `exec`
block — inherits the instance-global `tools.exec: {security: "allowlist",
ask: "on-miss"}`. No `emoji` in `identity` — user adds icons later. No
`thinkingDefault` — inherits `agents.defaults.thinkingDefault: "high"`.)

- [ ] **Step 2: Verify both agents parse**

Run: `jq -e '[.agents.list[] | select(.id=="elina" or .id=="elliot") | .name]' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `["Elina","Elliot"]` (no JSON parse error).

- [ ] **Step 3: Add both ids to `execApprovals.agentFilter`**

Replace (lines 714-723):

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
          "legal",
          "elina",
          "elliot"
        ],
```

- [ ] **Step 4: Verify the filter**

Run: `jq -e '[.channels.discord.execApprovals.agentFilter | index("elina"), index("elliot")]' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `[8,9]` (array indices; any two non-null ascending numbers are fine).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): add Elina and Elliot agent definitions"
```

---

### Task 2: Discord routing — bindings + guild channel entries

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json:673-684` (bindings array), `:808-817` (guild channels map)

**Interfaces:**
- Consumes: agent ids `elina` / `elliot` from Task 1; env placeholders `{{ .DISCORD_ELINA_CHANNEL_ID }}` / `{{ .DISCORD_ELLIOT_CHANNEL_ID }}` (rendered by external-secrets, fields added to 1Password by the user) and `{{ .DISCORD_GUILD_ID }}` (already present).
- Produces: bindings channel→agent for both; guild channel entries keyed `{{ .DISCORD_ELINA_CHANNEL_ID }}` / `{{ .DISCORD_ELLIOT_CHANNEL_ID }}`.

- [ ] **Step 1: Append both bindings**

Replace (end of bindings array, lines 673-684):

```json
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

with:

```json
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
    },
    {
      "agentId": "elina",
      "match": {
        "channel": "discord",
        "peer": {
          "kind": "channel",
          "id": "{{ .DISCORD_ELINA_CHANNEL_ID }}"
        },
        "guildId": "{{ .DISCORD_GUILD_ID }}"
      }
    },
    {
      "agentId": "elliot",
      "match": {
        "channel": "discord",
        "peer": {
          "kind": "channel",
          "id": "{{ .DISCORD_ELLIOT_CHANNEL_ID }}"
        },
        "guildId": "{{ .DISCORD_GUILD_ID }}"
      }
    }
  ],
```

- [ ] **Step 2: Verify the bindings**

Run: `jq -e '[.bindings[] | select(.agentId=="elina" or .agentId=="elliot") | .match.peer.id]' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `["{{ .DISCORD_ELINA_CHANNEL_ID }}","{{ .DISCORD_ELLIOT_CHANNEL_ID }}"]`.

- [ ] **Step 3: Add both guild channel entries**

Replace (legal channel entry followed by the Claw project forum entry, lines 808-817):

```json
            "{{ .DISCORD_LEGAL_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es Harvey, mon assistant juridique pour le droit français. Sois factuel, précis et intelligible."
            },
            "{{ .DISCORD_CLAW_PROJECT_FORUM }}": {
```

with (legal entry unchanged, the two new entries inserted between it and the forum entry):

```json
            "{{ .DISCORD_LEGAL_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es Harvey, mon assistant juridique pour le droit français. Sois factuel, précis et intelligible."
            },
            "{{ .DISCORD_ELINA_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es Elina, l'assistante d'Elina. Matt et Agnès te consultent pour suivre ses apprentissages, proposer des jeux adaptés et noter ses centres d'intérêt. Sois chaleureuse, créative et garde une trace de ce qui fonctionne."
            },
            "{{ .DISCORD_ELLIOT_CHANNEL_ID }}": {
              "enabled": true,
              "requireMention": false,
              "skills": [
                "search",
                "docs"
              ],
              "systemPrompt": "Tu es Elliot, l'assistant d'Elliot. Matt et Agnès te consultent pour suivre ses apprentissages, proposer des jeux adaptés et noter ses centres d'intérêt. Sois chaleureux, créatif et garde une trace de ce qui fonctionne."
            },
            "{{ .DISCORD_CLAW_PROJECT_FORUM }}": {
```

(One-line identity + purpose prompts, matching the other agent channels. The user
will personalize them post-boot; no charter lives in Git.)

- [ ] **Step 4: Verify the channel entries**

Run: `jq -r '.channels.discord.guilds["{{ .DISCORD_GUILD_ID }}"].channels | keys[] | select(test("ELINA|ELLIOT"))' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: both keys `{{ .DISCORD_ELINA_CHANNEL_ID }}` and `{{ .DISCORD_ELLIOT_CHANNEL_ID }}`.

- [ ] **Step 5: Full-file JSON sanity**

Run: `jq -e . kubernetes/apps/ai/mainclaw/app/resources/openclaw.json > /dev/null && echo OK`
Expected output: `OK`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): route Elina and Elliot Discord channels"
```

---

### Task 3: Cross-agent wiring — active-memory + agentToAgent

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json:1199-1209` (active-memory agents), `:1510-1519` (agentToAgent allow)

**Interfaces:**
- Consumes: agent ids `elina` / `elliot` from Task 1.
- Produces: both agents receive active-memory context injection and are reachable via inter-agent delegation (e.g. main/nova can ask them for tracked context).

- [ ] **Step 1: Add both ids to `active-memory.config.agents`**

Replace (lines 1199-1209):

```json
          "agents": [
            "main",
            "finance",
            "family",
            "shopping",
            "coach",
            "media",
            "nova",
            "lycos",
            "legal"
          ],
```

with:

```json
          "agents": [
            "main",
            "finance",
            "family",
            "shopping",
            "coach",
            "media",
            "nova",
            "lycos",
            "legal",
            "elina",
            "elliot"
          ],
```

- [ ] **Step 2: Verify active-memory**

Run: `jq -e '.plugins.entries["active-memory"].config.agents | index("elina"), index("elliot")' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `9` and `10` (array indices; any non-null numbers are fine).

- [ ] **Step 3: Add both ids to `tools.agentToAgent.allow`**

Replace (lines 1510-1519):

```json
      "allow": [
        "main",
        "family",
        "coach",
        "finance",
        "shopping",
        "media",
        "nova",
        "lycos"
      ],
```

with:

```json
      "allow": [
        "main",
        "family",
        "coach",
        "finance",
        "shopping",
        "media",
        "nova",
        "lycos",
        "elina",
        "elliot"
      ],
```

- [ ] **Step 4: Verify agentToAgent**

Run: `jq -e '.tools.agentToAgent.allow | index("elina"), index("elliot")' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`
Expected output: `9` and `10` (array indices; any non-null numbers are fine).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): wire Elina and Elliot into active-memory and agent-to-agent"
```

---

### Task 4: ExternalSecret channel ids + full pre-push validation

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml:29-31`

**Interfaces:**
- Consumes: 1Password item `mainclaw` fields `DISCORD_ELINA_CHANNEL_ID` / `DISCORD_ELLIOT_CHANNEL_ID` (user added both pre-implementation).
- Produces: env keys `DISCORD_ELINA_CHANNEL_ID` / `DISCORD_ELLIOT_CHANNEL_ID` in secret `mainclaw-secret`, consumed by the pod env and by the `mainclaw-config` rendered secret (via `dataFrom: extract: key: mainclaw`, no edit needed there).

- [ ] **Step 1: Add the template lines**

In `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml`, replace:

```yaml
        DISCORD_LYCOS_CHANNEL_ID: "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        DISCORD_LEGAL_CHANNEL_ID: "{{ .DISCORD_LEGAL_CHANNEL_ID }}"
        DISCORD_CLAW_PROJECT_FORUM: "{{ .DISCORD_CLAW_PROJECT_FORUM }}"
```

with:

```yaml
        DISCORD_LYCOS_CHANNEL_ID: "{{ .DISCORD_LYCOS_CHANNEL_ID }}"
        DISCORD_LEGAL_CHANNEL_ID: "{{ .DISCORD_LEGAL_CHANNEL_ID }}"
        DISCORD_ELINA_CHANNEL_ID: "{{ .DISCORD_ELINA_CHANNEL_ID }}"
        DISCORD_ELLIOT_CHANNEL_ID: "{{ .DISCORD_ELLIOT_CHANNEL_ID }}"
        DISCORD_CLAW_PROJECT_FORUM: "{{ .DISCORD_CLAW_PROJECT_FORUM }}"
```

- [ ] **Step 2: Run flate (full pre-push guard)**

Run: `mise exec -- flate test ks --path ./kubernetes/apps`
Expected: all Kustomizations pass (30-60s). If `flate test hr` is available, also run
`mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw` — expect PASS.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/externalsecret.yaml
git commit -m "feat(ai/mainclaw): wire Elina and Elliot channel ids into mainclaw secret"
```

---

### Task 5: Push + PR

**Files:**
- None (git operations only). Branch: `feat/mainclaw-elina-elliot` (stacked on `feat/mainclaw-legal-agent`).

**Interfaces:**
- Consumes: all commits from Tasks 1-4 plus the spec commit.
- Produces: PR URL (base `feat/mainclaw-legal-agent`) for user review; konflate will post rendered Flux diffs as a PR comment.

- [ ] **Step 1: Push the branch**

Run: `git push -u origin feat/mainclaw-elina-elliot`
Expected: branch created on origin, no rejection.

- [ ] **Step 2: Open the stacked PR**

Run:

```bash
gh pr create --base feat/mainclaw-legal-agent --title "feat(ai/mainclaw): add Elina and Elliot agents" --body "## Summary
- Two new agents in mainclaw \`openclaw.json\`: \`elina\` + \`elliot\` (personal agents for the children, parents-only access for now)
- Defaults-inherited model (\`litellm/MiniMax-M3\` + \`go-minimax-m3\`/\`dsv4f\` fallbacks — no \`model\` key), no heartbeat (reactive), no per-agent exec (inherits global allowlist policy), identity name-only (icons later)
- Discord bindings + guild channel entries for \`DISCORD_ELINA_CHANNEL_ID\` / \`DISCORD_ELLIOT_CHANNEL_ID\`, skills search/docs, one-line FR systemPrompts (user will personalize post-boot)
- Added to \`execApprovals.agentFilter\`, \`active-memory.config.agents\`, \`tools.agentToAgent.allow\`
- Both channel ids added to the \`mainclaw\` ExternalSecret (1Password fields already present)

## Validation
- jq checks on agents.list / bindings / guild channels / execApprovals / active-memory / agentToAgent
- flate test ks (full repo) PASS

## Post-merge checks
- \`kubectl get externalsecret mainclaw -n ai\` → SecretSynced
- Pod restarted by stakater reloader, openclaw boots clean (no schema rejection — \`identity\` without \`emoji\` is the only unproven shape)
- Discord round-trip in both channels; \`workspace-elina\` / \`workspace-elliot\` created on PVC

Design: docs/superpowers/specs/2026-09-05-mainclaw-elina-elliot-agents-design.md

_STACKED on feat/mainclaw-legal-agent — retarget base to main after the legal PR merges._"
```

Expected: PR URL printed.

- [ ] **Step 3: Report the PR URL to the user** (do not merge unless asked).

---

### Task 6 (post-merge): Deploy verification — only after the user merges (legal first, then this PR retargeted to main)

**Files:**
- None (read-only cluster checks).

- [ ] **Step 1: Secret rendered**

Run: `kubectl get externalsecret mainclaw -n ai`
Expected: `SecretSynced` (refresh 1h; force with `kubectl annotate externalsecret mainclaw -n ai force-sync=$(date +%s)` if needed).

Run: `kubectl get secret mainclaw-secret -n ai -o jsonpath='{.data.DISCORD_ELINA_CHANNEL_ID}' | base64 -d; echo`
Expected: the Elina channel id (non-empty, matching the 1Password field).

Run: `kubectl get secret mainclaw-secret -n ai -o jsonpath='{.data.DISCORD_ELLIOT_CHANNEL_ID}' | base64 -d; echo`
Expected: the Elliot channel id (non-empty, matching the 1Password field).

- [ ] **Step 2: Pod restarted clean**

Run: `kubectl get pods -n ai -l app.kubernetes.io/name=mainclaw` (check pod age) and
`kubectl logs -n ai <pod> | grep -iE 'elina|elliot|error' | head -20`
Expected: new pod age, no config-load/schema errors, agents `elina` and `elliot` registered.

- [ ] **Step 3: Discord round-trip**

User posts in each new channel; the matching agent replies. Then the agents can be
personalized (systemPrompt rewrite, workspace `.md` files, icons) — user-driven steps.
