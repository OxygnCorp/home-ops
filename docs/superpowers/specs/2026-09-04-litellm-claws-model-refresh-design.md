# LiteLLM + mainclaw/devclaw: 2026-09 Model Refresh (Benchmark & Quota Driven)

- **Date:** 2026-09-04
- **Status:** Approved design (pre-implementation)
- **Scope:** `kubernetes/apps/ai/litellm/app/resources/config.yaml`, `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, `kubernetes/apps/ai/devclaw/app/resources/openclaw.json`

## Problem

The three LLM subscriptions (MiniMax Token Plan Plus, OpenCode Zen Go basic, z.ai GLM Coding
Lite) expose newer models than what litellm currently routes, and openclaw agent assignments
predate them:

- mainclaw runs **everything** on `MiniMax-M3` via defaults (plugins included), z.ai models
  are not exposed to mainclaw at all.
- devclaw primary (`zai-glm-5.2`) and fallbacks (`zai-glm-4.7`) are one generation behind.
- `glm-5.1`, `zai-glm-4.7`, `zai-glm-5-turbo`, `go-kimi-k2.6` are obsolete or superseded.

Model discovery (live `/v1/models` on 2026-09-04) confirmed the new catalogs. Benchmarks from
Artificial Analysis (AA Intelligence Index v4.1.1, Sept 2026) and the opencode-go per-model
request quotas drive the assignment.

## Benchmark data (Artificial Analysis, 2026-09)

| Model | AA Index | Rank (class) | Speed | TTFT¹ | Ctx | Vision | Verbosity | opencode quota/mo |
|---|---|---|---|---|---|---|---|---|
| Grok 4.6 | 61 | #11/201 | 65 t/s | 52 s | 500k | yes | 72M | 845 (**unusable via API²**) |
| Kimi K3 | 60 | #1/112 | 40 t/s | 4.9 s | 1M | yes | 130M | **490** |
| GLM-5.3 | 60 | #2/112 | 84 t/s | 2.0 s | 1M | **no** | 170M | 1,080 (oc) + z.ai plan |
| Qwen3.8 Max | 58 | #24/201 | 39 t/s | 2.4 s | 1M | yes+video | 150M | **810** |
| GLM-5.3-Flash | 57 | #4/112 | 48 t/s | 1.7 s | 1M | **yes** | 150M | 7,900 (oc) + z.ai plan |
| DeepSeek V4 Pro | 53 | #6/112 | 62 t/s | 1.8 s | 1M | no | 130M | 5,200 |
| DeepSeek V4 Flash | 52 | #8/112 | 134 t/s | 1.2 s | 1M | no | 210M | **37,800** |
| GPT-5.6 Luna | 52 | #3/177 | 134 t/s | 170 s | 1M | yes | 130M | 10,250 (**500s via API²**) |
| MiniMax M3 | 45 | #12/112 | 90 t/s | 1.6 s | 1M | yes+video | **89M** | MiniMax pool (volume) |
| Kimi K2.7 Code | 43 | #16/112 | 42 t/s | 2.9 s | 256k | yes | 100M | 6,750 |

¹ AA "time to first **answer** token" on max/high effort variants — includes reasoning time.
  Live smoke tests (trivial prompt) measured **1.6–3.0 s** across all working models; the
  worst-case TTFTs are thinking-time artifacts, not infrastructure latency.

² Verified empirically 2026-09-04 from the litellm pod:
   - `grok-4.6`: HTTP 401 `ModelError: not supported for format oa-compat` **and** format
     anthropic → cannot be routed by litellm. Excluded.
   - `gpt-5.6-luna`: HTTP 500 (4/4 attempts, both formats) → added dormant, unassigned.
   - `deepseek-v4-flash` direct calls return `RegionError` with non-SDK user agents, but
     **works 100% through litellm** (verified with unique prompts / cache-miss). Known
     opencode routing quirk; production path unaffected.

## Design principles

1. **MiniMax Token Plan Plus = volume backbone** (heartbeats, subagents, plugins fallback,
   claw primary, imageModel) — largest capacity, renews regardless.
2. **z.ai GLM Coding Lite = devclaw + nova** — dedicated coding-plan endpoint, moderate
   volume, currently under-used.
3. **opencode-go basic = quality boosts** on moderate-traffic agents, spread across
   per-model quotas so each tight model (≤1,080/mo) serves at most one agent.
4. **Fallbacks always cross plans** so a provider outage/quota exhaust degrades, not fails.

## Assignments

### devclaw

| Slot | Primary | Fallbacks | Rationale |
|---|---|---|---|
| main (Puchu, k8s devops) | `zai-glm-5.3` | `go-glm-5.3`, `MiniMax-M3` | #2 open-weights (60), 84 t/s, TTFT 2 s, 1M ctx for logs; same model on second plan as FB1 |
| heartbeat | `MiniMax-M3` | — | unchanged; spares z.ai prompts |
| imageModel | `MiniMax-M3` | `go-glm-5.3-flash` | vision + concise; flash is vision-capable (replaces `go-kimi-k2.6`) |
| subagents | `MiniMax-M3` | `dsv4f` | unchanged |
| plugins (active-memory, lossless-claw) | `dsv4f` | `MiniMax-M2.7` | unchanged — 37.8k/mo quota is opencode's most generous |

### mainclaw

| Agent / slot | Primary | Fallbacks | Rationale |
|---|---|---|---|
| claw (Matt) — defaults | `MiniMax-M3` | `go-minimax-m3`, `dsv4f` | volume pool; concise (89M), 90 t/s, TTFT 1.6 s → fluent chat |
| nova (Agnès) | `zai-glm-5.3-flash` | `go-glm-5.3-flash`, `MiniMax-M3` | 57, TTFT 1.7 s, vision; loads the under-used z.ai plan |
| coach | `go-glm-5.3-flash` | `dsv4p`, `MiniMax-M3` | quality + reactivity for long pedagogic sessions |
| family | `go-qwen3.8-flash` | `go-minimax-m2.7`, `MiniMax-M2.7` | routine tier, 27k/mo |
| shopping | `go-qwen3.8-flash` | `dsv4f`, `go-minimax-m2.7` | routine tier, 27k/mo |
| media | `dsv4f` | `go-qwen3.8-flash`, `go-minimax-m2.7` | proven for *arr tooling; 134 t/s, TTFT 1.2 s |
| finance | `dsv4p` | `go-qwen3.8-max`, `MiniMax-M3` | 53, 1M ctx, 5.2k/mo; numeric reasoning |
| lycos (research) | `go-qwen3.8-max` | `zai-glm-5.3`, `MiniMax-M3` | 58, multimodal, 1M ctx; sporadic bursts fit 810/mo |
| imageModel (defaults) | `MiniMax-M3` | `go-glm-5.3-flash` | vision + concision (replaces `go-kimi-k2.6`) |
| subagents (defaults) | `MiniMax-M3` | `dsv4f` | unchanged |
| plugins (active-memory, lossless-claw) | `dsv4f` | `MiniMax-M2.7` | unchanged |

Quota concentration check: `qwen3.8-max` (810/mo) → lycos primary only (fallback-only for
finance); `glm-5.3` (1,080/mo oc) → devclaw FB1 only; `zai-glm-5.3` → devclaw primary +
lycos FB1; everything high-volume lands on ≥5k/mo quotas or the MiniMax pool.

### Available via `/model`, unassigned

`go-kimi-k3` (60 — 490/mo too tight for routine use), `go-gpt-5.6-luna` (dormant, pending
upstream fix), `go-kimi-k2.7-code`, `go-hy4-preview`, `go-dsv4f-vision`,
`MiniMax-M2.7-highspeed`, plus existing `dsv4p`, `go-qwen3.7-plus`, `mimo-*`, `go-minimax-*`.

## LiteLLM changes (`resources/config.yaml`)

### Additions

| model_name | upstream | api_base | model_info (in/out tokens, vision) |
|---|---|---|---|
| `MiniMax-M2.7-highspeed` | `minimax/MiniMax-M2.7-highspeed` | MiniMax | 204800 / 131072, no vision |
| `go-kimi-k3` | `openai/kimi-k3` | opencode | 1000000 / 32768, vision |
| `go-kimi-k2.7-code` | `openai/kimi-k2.7-code` | opencode | 262144 / 16384, vision |
| `go-glm-5.3` | `openai/glm-5.3` | opencode | 1000000 / 131072, no vision |
| `go-glm-5.3-flash` | `openai/glm-5.3-flash` | opencode | 1000000 / 32768, vision |
| `go-qwen3.8-max` | `openai/qwen3.8-max` | opencode | 1000000 / 16384, vision |
| `go-qwen3.8-flash` | `openai/qwen3.8-flash` | opencode | 262144 / 16384, no vision |
| `go-grok-4.6` | — | — | **not added** (401 both formats) |
| `go-gpt-5.6-luna` | `openai/gpt-5.6-luna` | opencode | 1000000 / 32768, vision — dormant |
| `go-hy4-preview` | `openai/hy4-preview` | opencode | 131072 / 16384, no vision |
| `go-dsv4f-vision` | `openai/deepseek-v4-flash-vision-exp` | opencode | 1000000 / 16384, vision |
| `zai-glm-5.3` | `openai/glm-5.3` | z.ai | 1000000 / 131072, no vision |
| `zai-glm-5.3-flash` | `openai/glm-5.3-flash` | z.ai | 1000000 / 32768, vision |

Excluded per user: `omen-alpha`, `longcat-2.0`; `grok-4.6` excluded per live API check.
Context windows from AA data; `qwen3.8-flash`/`hy4-preview` values are conservative
placeholders to confirm during post-deploy smoke test.

### Removals

`glm-5.1`, `zai-glm-4.7`, `zai-glm-5-turbo`, `go-kimi-k2.6`.

### Router fallbacks

| Model | Old fallback | New fallback |
|---|---|---|
| `MiniMax-M3` | `go-minimax-m3` | unchanged |
| `MiniMax-M2.7` | `go-minimax-m2.7` | unchanged |
| `dsv4f` | `go-minimax-m3` | unchanged |
| `zai-glm-5.2` | `zai-glm-4.7` | `zai-glm-5.3-flash` |
| `zai-glm-5.3` | — | `zai-glm-5.3-flash` |
| `zai-glm-5.3-flash` | — | `go-glm-5.3-flash` |
| `go-glm-5.3` | — | `zai-glm-5.3` |
| `go-glm-5.3-flash` | — | `zai-glm-5.3-flash` |
| `go-qwen3.8-max` | — | `dsv4p` |
| `go-gpt-5.6-luna` | — | (none — dormant) |

## openclaw changes

Both `openclaw.json` files:

1. **Advertised provider model list** (`models.providers.litellm.models`): remove `glm-5.1`,
   `zai-glm-4.7`, `go-kimi-k2.6`; add every model referenced by the assignment tables above
   (mainclaw: +`go-qwen3.8-max/flash`, `go-glm-5.3-flash`, `zai-glm-5.3`, `zai-glm-5.3-flash`
   — `dsv4p` already present; devclaw: +`zai-glm-5.3`, `zai-glm-5.3-flash`, `go-glm-5.3`,
   `go-glm-5.3-flash`, `go-qwen3.8-flash`). Costs stay `0` for subscription models, MiniMax pricing unchanged.
2. **Alias map** (`agents.defaults.models`): remove deleted models; add new aliases
   (`glm-5.3`→`zai-glm-5.3` family, `glm-5.3-flash`, `qwen3.8-max`→`qwen-max`,
   `qwen3.8-flash`→`qwen-flash`), all with `cache_prompt: true` (MiniMax entries keep
   `cacheRetention: short`).
3. **devclaw**: `agents.defaults.model` → primary `zai-glm-5.3`, fallbacks
   `go-glm-5.3`, `MiniMax-M3`. `imageModel` fallback → `go-glm-5.3-flash`. Heartbeat stays
   `MiniMax-M3`.
4. **mainclaw**: defaults unchanged (claw inherits M3). Add explicit per-agent `model`
   overrides for `nova`, `coach`, `family`, `shopping`, `media`, `finance`, `lycos` per the
   table. `imageModel` fallback → `go-glm-5.3-flash`.
5. Plugins, subagents, heartbeats: **no model changes**.

## Validation

1. `flate test ks --path ./kubernetes/apps` + `flate test hr` (pre-push guard).
2. Post-deploy: `kubectl exec` smoke test through litellm (`localhost:4000`) with unique
   prompts for every added model — expect 2–4 s responses; confirm `go-gpt-5.6-luna` status
   and remove it if still 500.
3. `flux reconcile` the three Kustomizations; check `litellm-configmap`,
   `mainclaw-config`/`devclaw-config` ExternalSecrets refresh (1 min cadence).
4. Watch mainclaw/devclaw pods for config-load errors; verify a Discord round-trip per claw.

## Risks & rollback

- **Per-agent model overrides in mainclaw** are new structure — schema-validated by openclaw
  on boot; a bad key would fail loudly at startup (rolling restart, kopia-backed).
- **gpt-5.6-luna dormant entry** may 500 — harmless (unassigned), removed if confirmed.
- **Verbose models on interactive agents**: GLM-5.3-Flash is "somewhat verbose" (150M) —
  mitigated by openclaw `typingMode: instant` + streaming progress; revisit if messages
  flood.
- Rollback = `git revert` of the PR; Flux re-applies previous ConfigMaps within one reconcile.

## Out of scope

- headroom proxy (transparent pass-through, no model allowlist to update)
- memini / lightrag consumers of litellm (use their own pinned models, unaffected by
  additions; unaffected by removals — verified none reference the four removed models)
- Renovate automation for model catalogs (manual refresh by design)
