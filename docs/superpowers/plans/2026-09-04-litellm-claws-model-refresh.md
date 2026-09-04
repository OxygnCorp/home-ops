# LiteLLM + Claws Model Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refresh litellm's model catalog (12 additions, 4 removals, router fallback updates) and reassign mainclaw/devclaw agent models per the benchmark & quota driven spec.

**Architecture:** Three GitOps-managed config files (litellm YAML ConfigMap source, two openclaw JSON ConfigMap sources). Order matters: litellm first so models exist before the claws reference them. Flux picks up changes post-merge; verification includes flate validation pre-push and live smoke tests post-merge.

**Tech Stack:** Flux GitOps, litellm v1.99.1, openclaw 2026.9.1, flate (via mise), jq, gh CLI.

**Spec:** `docs/superpowers/specs/2026-09-04-litellm-claws-model-refresh-design.md`

## Global Constraints

- Branch: `litellm-claws-model-refresh` (already exists, spec committed). Never commit on `main`.
- Model names must match the spec exactly (`zai-glm-5.3`, `go-glm-5.3-flash`, `go-qwen3.8-max`, `go-qwen3.8-flash`, `go-dsv4f-vision`, `MiniMax-M2.7-highspeed`, etc.).
- `mise exec -- flate test hr --path ./kubernetes/apps/ai/<app>` must pass before each commit.
- No plain-text secrets; API keys stay as `os.environ/...` references.
- Do NOT add `metadata.namespace` to any resource (injected by kustomize).
- Excluded models (never reference): `grok-4.6`, `omen-alpha`, `longcat-2.0`, `glm-5.1`, `zai-glm-4.7`, `zai-glm-5-turbo`, `go-kimi-k2.6`.
- `go-gpt-5.6-luna` is added to litellm but assigned to **no** agent (dormant).

---

### Task 1: litellm — model catalog + router fallbacks

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/resources/config.yaml`

**Interfaces:**
- Produces: litellm model names `zai-glm-5.3`, `zai-glm-5.3-flash`, `go-glm-5.3`, `go-glm-5.3-flash`, `go-qwen3.8-max`, `go-qwen3.8-flash`, `go-kimi-k3`, `go-kimi-k2.7-code`, `go-gpt-5.6-luna`, `go-hy4-preview`, `go-dsv4f-vision`, `MiniMax-M2.7-highspeed` — consumed by Tasks 2–3 as `litellm/<model_name>`.

- [ ] **Step 1: Remove the 4 obsolete model blocks**

Delete these complete `model_list` entries from `kubernetes/apps/ai/litellm/app/resources/config.yaml`:

```yaml
  - model_name: glm-5.1
    model_info: {mode: chat, max_input_tokens: 203000, max_output_tokens: 16384, supports_function_calling: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5.1
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY
```

```yaml
  - model_name: go-kimi-k2.6
    model_info: {mode: chat, max_input_tokens: 262144, max_output_tokens: 16384, supports_function_calling: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/kimi-k2.6
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY
```

```yaml
  - model_name: zai-glm-4.7
    model_info: {mode: chat, max_input_tokens: 204800, max_output_tokens: 131072, supports_function_calling: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-4.7
      api_base: https://api.z.ai/api/coding/paas/v4
      api_key: os.environ/ZAI_API_KEY
```

```yaml
  - model_name: zai-glm-5-turbo
    model_info: {mode: chat, max_input_tokens: 204800, max_output_tokens: 131072, supports_function_calling: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5-turbo
      api_base: https://api.z.ai/api/coding/paas/v4
      api_key: os.environ/ZAI_API_KEY
```

- [ ] **Step 2: Add 12 new model blocks**

Insert after the `MiniMax-M2.7` block (keeps MiniMax entries grouped):

```yaml
  # MiniMax M2.7 highspeed - fast tier (MiniMax token plan plus)
  - model_name: MiniMax-M2.7-highspeed
    model_info: {mode: chat, max_input_tokens: 204800, max_output_tokens: 131072, supports_function_calling: true, supports_vision: false, supports_prompt_caching: true}
    litellm_params:
      model: minimax/MiniMax-M2.7-highspeed
      api_base: https://api.minimax.io/v1
      api_key: os.environ/MINIMAX_API_KEY
```

Insert after the `dsv4p` block (opencode group, before `go-kimi-k2.6`'s old position):

```yaml
  # OpenCode Zen Go (subscription) - new generation
  - model_name: go-kimi-k3
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 32768, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/kimi-k3
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-kimi-k2.7-code
    model_info: {mode: chat, max_input_tokens: 262144, max_output_tokens: 16384, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/kimi-k2.7-code
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-glm-5.3
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 131072, supports_function_calling: true, supports_vision: false, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5.3
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-glm-5.3-flash
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 32768, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5.3-flash
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-qwen3.8-max
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 16384, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/qwen3.8-max
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-qwen3.8-flash
    model_info: {mode: chat, max_input_tokens: 262144, max_output_tokens: 16384, supports_function_calling: true, supports_vision: false, supports_prompt_caching: true}
    litellm_params:
      model: openai/qwen3.8-flash
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  # Dormant: upstream returned HTTP 500 on 4/4 attempts 2026-09-04. Unassigned.
  - model_name: go-gpt-5.6-luna
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 32768, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/gpt-5.6-luna
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-hy4-preview
    model_info: {mode: chat, max_input_tokens: 131072, max_output_tokens: 16384, supports_function_calling: true, supports_vision: false, supports_prompt_caching: true}
    litellm_params:
      model: openai/hy4-preview
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY

  - model_name: go-dsv4f-vision
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 16384, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/deepseek-v4-flash-vision-exp
      api_base: https://opencode.ai/zen/go/v1
      api_key: os.environ/OPENCODE_API_KEY
```

Insert after the `zai-glm-5.2` block (z.ai group):

```yaml
  - model_name: zai-glm-5.3
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 131072, supports_function_calling: true, supports_vision: false, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5.3
      api_base: https://api.z.ai/api/coding/paas/v4
      api_key: os.environ/ZAI_API_KEY

  - model_name: zai-glm-5.3-flash
    model_info: {mode: chat, max_input_tokens: 1000000, max_output_tokens: 32768, supports_function_calling: true, supports_vision: true, supports_prompt_caching: true}
    litellm_params:
      model: openai/glm-5.3-flash
      api_base: https://api.z.ai/api/coding/paas/v4
      api_key: os.environ/ZAI_API_KEY
```

- [ ] **Step 3: Update router fallbacks**

Replace the whole `fallbacks:` list under `router_settings` with:

```yaml
  fallbacks:
    - MiniMax-M3: ["go-minimax-m3"]
    - MiniMax-M2.7: ["go-minimax-m2.7"]
    - dsv4f: ["go-minimax-m3"]
    - zai-glm-5.2: ["zai-glm-5.3-flash"]
    - zai-glm-5.3: ["zai-glm-5.3-flash"]
    - zai-glm-5.3-flash: ["go-glm-5.3-flash"]
    - go-glm-5.3: ["zai-glm-5.3"]
    - go-glm-5.3-flash: ["zai-glm-5.3-flash"]
    - go-qwen3.8-max: ["dsv4p"]
```

- [ ] **Step 4: Validate**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm
python3 -c "import yaml; d=yaml.safe_load(open('kubernetes/apps/ai/litellm/app/resources/config.yaml')); names=[m['model_name'] for m in d['model_list']]; assert len(names)==len(set(names)), 'dupes'; assert 'glm-5.1' not in names and 'zai-glm-4.7' not in names and 'zai-glm-5-turbo' not in names and 'go-kimi-k2.6' not in names; assert 'zai-glm-5.3' in names and 'go-glm-5.3-flash' in names; print('OK', len(names), 'models')"
```

Expected: flate passes; `OK 22 models` (14 - 4 + 12).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/litellm/app/resources/config.yaml
git commit -m "feat(ai/litellm): refresh model catalog (12 adds, 4 removals, router fallbacks)"
```

---

### Task 2: devclaw — primary glm-5.3, aliases, advertised list

**Files:**
- Modify: `kubernetes/apps/ai/devclaw/app/resources/openclaw.json`

**Interfaces:**
- Consumes: litellm model names from Task 1.
- Produces: devclaw config where `agents.defaults.model.primary == "litellm/zai-glm-5.3"`.

- [ ] **Step 1: Update defaults.model and imageModel**

In `agents.defaults`, replace:

```json
      "model": {
        "primary": "litellm/zai-glm-5.2",
        "fallbacks": [
          "litellm/zai-glm-4.7",
          "litellm/MiniMax-M3"
        ]
      },
```

with:

```json
      "model": {
        "primary": "litellm/zai-glm-5.3",
        "fallbacks": [
          "litellm/go-glm-5.3",
          "litellm/MiniMax-M3"
        ]
      },
```

Replace:

```json
      "imageModel": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-kimi-k2.6"
        ]
      },
```

with:

```json
      "imageModel": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-glm-5.3-flash"
        ]
      },
```

- [ ] **Step 2: Update the alias map**

In `agents.defaults.models`, delete the three lines:

```json
        "litellm/glm-5.1": { "alias": "glm-5.1", "params": { "cache_prompt": true } },
        "litellm/zai-glm-4.7": { "alias": "glm-4.7", "params": { "cache_prompt": true } },
        "litellm/go-kimi-k2.6": { "alias": "go-kimi-2.6", "params": { "cache_prompt": true } },
```

Add after the `"litellm/zai-glm-5.2"` line:

```json
        "litellm/zai-glm-5.3": { "alias": "glm-5.3", "params": { "cache_prompt": true } },
        "litellm/zai-glm-5.3-flash": { "alias": "glm-5.3-flash", "params": { "cache_prompt": true } },
        "litellm/go-glm-5.3": { "alias": "go-glm-5.3", "params": { "cache_prompt": true } },
        "litellm/go-glm-5.3-flash": { "alias": "go-glm-5.3-flash", "params": { "cache_prompt": true } },
        "litellm/go-qwen3.8-flash": { "alias": "qwen-flash", "params": { "cache_prompt": true } },
```

- [ ] **Step 3: Update the advertised model list**

In `models.providers.litellm.models`, delete the entries with `"id": "glm-5.1"`, `"id": "zai-glm-4.7"`, `"id": "go-kimi-k2.6"`. Add after the `"id": "zai-glm-5.2"` entry:

```json
          { "id": "zai-glm-5.3", "name": "z.ai GLM 5.3", "reasoning": true, "input": ["text"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 1000000, "maxTokens": 131072 },
          { "id": "zai-glm-5.3-flash", "name": "z.ai GLM 5.3 Flash", "reasoning": true, "input": ["text", "image"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 1000000, "maxTokens": 32768 },
          { "id": "go-glm-5.3", "name": "OpenCode Go GLM 5.3", "reasoning": true, "input": ["text"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 1000000, "maxTokens": 131072 },
          { "id": "go-glm-5.3-flash", "name": "OpenCode Go GLM 5.3 Flash", "reasoning": true, "input": ["text", "image"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 1000000, "maxTokens": 32768 },
          { "id": "go-qwen3.8-flash", "name": "OpenCode Go Qwen3.8 Flash", "reasoning": true, "input": ["text"], "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }, "contextWindow": 262144, "maxTokens": 16384 }
```

- [ ] **Step 4: Validate**

```bash
jq -e '.agents.defaults.model.primary == "litellm/zai-glm-5.3" and .agents.defaults.model.fallbacks == ["litellm/go-glm-5.3", "litellm/MiniMax-M3"] and .agents.defaults.imageModel.fallbacks == ["litellm/go-glm-5.3-flash"]' kubernetes/apps/ai/devclaw/app/resources/openclaw.json
jq -e '([.models.providers.litellm.models[].id] | index("glm-5.1") == null) and ([.models.providers.litellm.models[].id] | index("zai-glm-4.7") == null) and ([.models.providers.litellm.models[].id] | index("go-kimi-k2.6") == null) and ([.models.providers.litellm.models[].id] | index("zai-glm-5.3") != null)' kubernetes/apps/ai/devclaw/app/resources/openclaw.json
mise exec -- flate test hr --path ./kubernetes/apps/ai/devclaw
```

Expected: both `jq` calls print config and exit 0; flate passes.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/devclaw/app/resources/openclaw.json
git commit -m "feat(ai/devclaw): primary zai-glm-5.3, refresh model catalog and aliases"
```

---

### Task 3: mainclaw — per-agent model overrides, aliases, advertised list

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`

**Interfaces:**
- Consumes: litellm model names from Task 1.
- Produces: per-agent `model` overrides for nova, coach, family, shopping, media, finance, lycos; claw inherits defaults (unchanged `MiniMax-M3`).

- [ ] **Step 1: Update defaults fallbacks and imageModel**

In `agents.defaults`, replace:

```json
      "model": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-minimax-m3",
          "litellm/dsv4f",
          "litellm/go-kimi-k2.6"
        ]
      },
```

with:

```json
      "model": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-minimax-m3",
          "litellm/dsv4f"
        ]
      },
```

Replace:

```json
      "imageModel": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-kimi-k2.6"
        ]
      },
```

with:

```json
      "imageModel": {
        "primary": "litellm/MiniMax-M3",
        "fallbacks": [
          "litellm/go-glm-5.3-flash"
        ]
      },
```

- [ ] **Step 2: Add per-agent model overrides**

In `agents.list`, add a `"model"` key to each agent entry (place it right after `"agentDir"` in each block):

`family`:

```json
        "model": {
          "primary": "litellm/go-qwen3.8-flash",
          "fallbacks": ["litellm/go-minimax-m2.7", "litellm/MiniMax-M2.7"]
        },
```

`coach`:

```json
        "model": {
          "primary": "litellm/go-glm-5.3-flash",
          "fallbacks": ["litellm/dsv4p", "litellm/MiniMax-M3"]
        },
```

`finance`:

```json
        "model": {
          "primary": "litellm/dsv4p",
          "fallbacks": ["litellm/go-qwen3.8-max", "litellm/MiniMax-M3"]
        },
```

`shopping`:

```json
        "model": {
          "primary": "litellm/go-qwen3.8-flash",
          "fallbacks": ["litellm/dsv4f", "litellm/go-minimax-m2.7"]
        },
```

`media`:

```json
        "model": {
          "primary": "litellm/dsv4f",
          "fallbacks": ["litellm/go-qwen3.8-flash", "litellm/go-minimax-m2.7"]
        },
```

`nova`:

```json
        "model": {
          "primary": "litellm/zai-glm-5.3-flash",
          "fallbacks": ["litellm/go-glm-5.3-flash", "litellm/MiniMax-M3"]
        },
```

`lycos`:

```json
        "model": {
          "primary": "litellm/go-qwen3.8-max",
          "fallbacks": ["litellm/zai-glm-5.3", "litellm/MiniMax-M3"]
        },
```

The `main` (claw) agent gets **no** override — it inherits `MiniMax-M3` from defaults.

- [ ] **Step 3: Update the alias map**

In `agents.defaults.models`, delete the two lines:

```json
        "litellm/glm-5.1": {
          "alias": "glm-5.1",
          "params": {
            "cache_prompt": true
          }
        },
        "litellm/go-kimi-k2.6": {
          "alias": "go-kimi-2.6",
          "params": {
            "cache_prompt": true
          }
        },
```

Add these entries (alphabetical placement next to their families):

```json
        "litellm/go-glm-5.3-flash": {
          "alias": "go-glm-5.3-flash",
          "params": {
            "cache_prompt": true
          }
        },
        "litellm/go-qwen3.8-flash": {
          "alias": "qwen-flash",
          "params": {
            "cache_prompt": true
          }
        },
        "litellm/go-qwen3.8-max": {
          "alias": "qwen-max",
          "params": {
            "cache_prompt": true
          }
        },
        "litellm/zai-glm-5.3": {
          "alias": "glm-5.3",
          "params": {
            "cache_prompt": true
          }
        },
        "litellm/zai-glm-5.3-flash": {
          "alias": "glm-5.3-flash",
          "params": {
            "cache_prompt": true
          }
        },
```

- [ ] **Step 4: Update the advertised model list**

In `models.providers.litellm.models`, delete the entries with `"id": "glm-5.1"` and `"id": "go-kimi-k2.6"`. Add after the `"id": "mimo-v2.5-pro"` entry:

```json
          {
            "id": "zai-glm-5.3",
            "name": "z.ai GLM 5.3",
            "reasoning": true,
            "input": [
              "text"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 1000000,
            "maxTokens": 131072
          },
          {
            "id": "zai-glm-5.3-flash",
            "name": "z.ai GLM 5.3 Flash",
            "reasoning": true,
            "input": [
              "text",
              "image"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 1000000,
            "maxTokens": 32768
          },
          {
            "id": "go-glm-5.3-flash",
            "name": "OpenCode Go GLM 5.3 Flash",
            "reasoning": true,
            "input": [
              "text",
              "image"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 1000000,
            "maxTokens": 32768
          },
          {
            "id": "go-qwen3.8-max",
            "name": "OpenCode Go Qwen3.8 Max",
            "reasoning": true,
            "input": [
              "text",
              "image"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 1000000,
            "maxTokens": 16384
          },
          {
            "id": "go-qwen3.8-flash",
            "name": "OpenCode Go Qwen3.8 Flash",
            "reasoning": true,
            "input": [
              "text"
            ],
            "cost": {
              "input": 0,
              "output": 0,
              "cacheRead": 0,
              "cacheWrite": 0
            },
            "contextWindow": 262144,
            "maxTokens": 16384
          }
```

- [ ] **Step 5: Validate**

```bash
jq -e '.agents.list | map(select(.id == "nova"))[0].model.primary == "litellm/zai-glm-5.3-flash"' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
jq -e '.agents.list | map(select(.id == "lycos"))[0].model.primary == "litellm/go-qwen3.8-max"' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
jq -e '.agents.list | map(select(.id == "main"))[0].model == null' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
jq -e '([.models.providers.litellm.models[].id] | index("glm-5.1") == null) and ([.models.providers.litellm.models[].id] | index("go-kimi-k2.6") == null) and ([.models.providers.litellm.models[].id] | index("go-qwen3.8-max") != null)' kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw
```

Expected: all `jq` calls exit 0; flate passes.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/resources/openclaw.json
git commit -m "feat(ai/mainclaw): per-agent model overrides (nova/coach/family/shopping/media/finance/lycos)"
```

---

### Task 4: Full validation, push, PR

**Files:**
- None modified (verification only).

- [ ] **Step 1: Whole-tree validation**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps
```

Expected: both pass.

- [ ] **Step 2: Review the diff**

```bash
git diff origin/main --stat
git diff origin/main -- kubernetes/apps/ai/litellm kubernetes/apps/ai/mainclaw kubernetes/apps/ai/devclaw
```

Expected: exactly 3 files changed (litellm config.yaml, 2 openclaw.json) + the spec doc.

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin litellm-claws-model-refresh
gh pr create --title "feat(ai): litellm + claws model refresh (benchmark & quota driven)" --body "$(cat <<'EOF'
## Summary
- litellm: +12 models (glm-5.3/flash z.ai+oc, qwen3.8 max/flash, kimi-k3, k2.7-code, hy4, dsv4f-vision, M2.7-highspeed, luna dormant), -4 obsolete (glm-5.1, zai-glm-4.7, zai-glm-5-turbo, go-kimi-k2.6), router fallbacks updated
- devclaw: primary zai-glm-5.3, FB go-glm-5.3 → MiniMax-M3
- mainclaw: per-agent primaries (nova=zai-glm-5.3-flash, coach=go-glm-5.3-flash, family/shopping=go-qwen3.8-flash, media=dsv4f, finance=dsv4p, lycos=go-qwen3.8-max); claw unchanged (MiniMax-M3)

Design: docs/superpowers/specs/2026-09-04-litellm-claws-model-refresh-design.md
EOF
)"
```

Expected: PR URL printed. Do **not** merge — user reviews.

---

### Task 5: Post-merge cluster verification

**Files:**
- None modified (cluster-side checks only). Run after the PR is merged and Flux reconciles (~2 min).

- [ ] **Step 1: Confirm Flux rollout**

```bash
flux reconcile kustomization litellm -n ai --with-source
flux reconcile kustomization devclaw -n ai --with-source
flux reconcile kustomization mainclaw -n ai --with-source
kubectl -n ai rollout status deploy/litellm --timeout=180s
kubectl -n ai get pods -l 'app.kubernetes.io/name in (litellm,mainclaw,devclaw)'
```

Expected: all deployments Ready. litellm restarts (ConfigMap change); mainclaw/devclaw restart via templated Secret refresh (1 min cadence).

- [ ] **Step 2: Smoke test every new model through litellm**

```bash
LITELLM_POD=$(kubectl -n ai get pod -l app.kubernetes.io/name=litellm -o name | head -1)
kubectl exec -n ai $LITELLM_POD -- python -c "
import os, json, time, urllib.request, urllib.error, uuid
models = ['MiniMax-M2.7-highspeed', 'go-kimi-k3', 'go-kimi-k2.7-code', 'go-glm-5.3', 'go-glm-5.3-flash',
          'go-qwen3.8-max', 'go-qwen3.8-flash', 'go-gpt-5.6-luna', 'go-hy4-preview', 'go-dsv4f-vision',
          'zai-glm-5.3', 'zai-glm-5.3-flash']
fails = []
for m in models:
    tag = uuid.uuid4().hex[:6]
    payload = {'model': m, 'messages': [{'role': 'user', 'content': f'echo {tag}'}], 'max_tokens': 50}
    req = urllib.request.Request('http://localhost:4000/v1/chat/completions', data=json.dumps(payload).encode(),
        headers={'Authorization': 'Bearer ' + os.environ['LITELLM_MASTER_KEY'], 'Content-Type': 'application/json'})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            json.loads(r.read())
            print(f'{m:24s} OK  {time.time()-t0:4.1f}s')
    except Exception as e:
        print(f'{m:24s} FAIL {str(e)[:80]}'); fails.append(m)
print('FAILURES:', fails if fails else 'none (luna expected-fail acceptable: dormant)')
"
```

Expected: all OK except possibly `go-gpt-5.6-luna` (dormant, known 500s). If any **other** model fails, stop and investigate before proceeding.

- [ ] **Step 3: Check claw startup health**

```bash
kubectl -n ai logs deploy/mainclaw --tail=50 | grep -iE 'model|provider|error' | tail -20
kubectl -n ai logs deploy/devclaw --tail=50 | grep -iE 'model|provider|error' | tail -20
kubectl -n ai get externalsecret mainclaw-config devclaw-config -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[-1].type}{"\n"}{end}'
```

Expected: no model/provider load errors; ExternalSecrets `Ready=True`.

- [ ] **Step 4: If luna still 500s, remove it**

Only if Task 5 Step 2 showed `go-gpt-5.6-luna` failing:

```bash
# Remove the go-gpt-5.6-luna block from config.yaml, then:
mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm
git add kubernetes/apps/ai/litellm/app/resources/config.yaml
git commit -m "fix(ai/litellm): remove dormant go-gpt-5.6-luna (persistent upstream 500)"
git push
```
