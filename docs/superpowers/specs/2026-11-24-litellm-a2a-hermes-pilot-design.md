# LiteLLM ↔ Hermes A2A pilot — design

**Date:** 2026-11-24
**Status:** Approved design, pending implementation plan
**Namespace:** `ai` · **LiteLLM:** `ghcr.io/berriai/litellm-database:1.110.3` · **Hermes:** `v0.23.3`

## Goal

Make LiteLLM the cluster's A2A broker for one agent — the existing Hermes instance — as the first step of recommendation A from the LiteLLM feature survey. A caller sends an A2A `message/send` to LiteLLM (`POST /a2a/hermes`), LiteLLM discovers and invokes Hermes over A2A v1.0, and Hermes answers from its live gateway session (including memini memory). The pilot proves discovery (`agent_search`, `/v1/agents`), authenticated invocation, and end-to-end observability before any other agent is federated.

### Decisions (approved 2026-11-23/24)

- **Scope:** Hermes only. `mainclaw`, `devclaw`, their OpenClaw configs, and all virtual keys/teams stay unchanged.
- **Exposure:** cluster-only `ClusterIP` Service; no HTTPRoute, no public URL. Bearer token per peer, held in 1Password.
- **Registration:** declarative top-level `agents:` in the `LiteLLMProxy` CR's `extraConfig` (GitOps source of truth), not via UI/API.
- **Validation caller:** a short-lived, uncommitted Job in `ai`; no devclaw config change in this step.
- **Approaches rejected:** API/UI registration (`static_headers` stores the token in LiteLLM's DB and the agent is not versioned); direct Hermes exposure without LiteLLM (does not test the broker).

## Verified prerequisites

- Recommendation B is merged (PR #5991, merge commit `847e1763`) and live: the `litellm` Kustomization reconciled revision `dcfcd3a`, the ConfigMap contains both `agent_search_embedding_model` and `skill_search_embedding_model`, the rollout completed, and `agent_search` / `skill_search` now answer with `[]` instead of `*_not_configured`. The registries are empty — this pilot fills the agent side.
- LiteLLM v1.110.2 > v1.96.0, so the config top-level `agents:` key is read correctly even with a database attached. Required fields are `agent_name` and `agent_card_params`; entries missing either are skipped at startup. Config-defined agents are not editable in the UI and survive DB reloads.
- `litellm_params.api_key` with `os.environ/<VAR>` is the documented A2A outbound bearer mechanism (`Authorization: Bearer <api_key>`); no `auth_type` field exists for A2A agents.
- Hermes v0.23.x ships `plugins/platforms/a2a` with A2A v1.0 inbound (`/.well-known/agent-card.json`, legacy `/.well-known/agent.json`, JSON-RPC `message/send` etc.) and outbound toolsets. A non-loopback bind requires both a token and explicit `A2A_HOST`; a token alone falls back to caller-IP identity and dispatch is refused for unknown identities unless `A2A_TRUSTED_PEERS` names the peer (or `A2A_ALLOW_ALL_USERS=true`, dev-only). `A2A_PEER_TOKENS=name:token` gives a stable, IP-independent identity.
- The existing LiteLLM `ExternalSecret` uses `dataFrom.extract` on the 1Password item `litellm` (so the new field is fetched automatically), but its `target.template` with the default `mergePolicy: Replace` writes **only the keys mapped in `template.data`** into `litellm-secret` — so the token needs an explicit `A2A_HERMES_TOKEN: "{{ .A2A_HERMES_TOKEN }}"` mapping there. `extraConfig.environment` then injects the same-named env var into the proxy pods.
- The existing Secret `litellm-key-opencode` in `ai` has key `api-key` and is suitable for the Job (no new virtual key needed).

## Architecture and call flow

```
Job (ai, ephemeral) --JSON-RPC message/send--> LiteLLM /a2a/hermes
                                               |  virtual key auth
                                               |  agent registry + card + Lens trace
                                               v
                                    Hermes :9900 (A2A platform)
                                               |  peer identity "litellm"
                                               v
                                    live Hermes session + memini
```

1. LiteLLM registers `hermes` from `extraConfig.agents` with `agent_card_params.url = http://hermes.ai.svc.cluster.local:9900` and `protocolVersion: "1.0"`. It fetches Hermes' card from `/.well-known/agent-card.json`; Hermes advertises the same cluster-internal URL via `A2A_PUBLIC_URL` so the card never leaks a bind address.
2. The Job authenticates to LiteLLM with `x-litellm-api-key: Bearer <existing virtual key>` and posts JSON-RPC `message/send` to `/a2a/hermes`. LiteLLM sends `Authorization: Bearer <A2A_HERMES_TOKEN>` upstream via `litellm_params.api_key`.
3. Hermes maps the token to the peer name `litellm` via `A2A_PEER_TOKENS`, accepts it via `A2A_TRUSTED_PEERS=litellm`, injects the task into its live gateway session, and returns the reply over A2A. Audit goes to `a2a_audit.jsonl`; LiteLLM records the invocation in Lens.
4. `agent_search` (already embedding-enabled) ranks the registered Hermes card for task queries; `/v1/agents` remains the authoritative discovery endpoint.

Non-goals: streaming (`message/stream`), push notifications, task APIs beyond `message/send`, per-team agent permissions (operator CRDs have no `agents`/`object_permission` field — default open access is unchanged), skill-hub, budgets/kill-switch, any other app's A2A enablement.

## File-by-file changes

### `kubernetes/apps/ai/hermes/app/configmap.yaml`

Under the existing `gateway:` block (alongside `multiplex_profiles: false`):

```yaml
    gateway:
      multiplex_profiles: false
      platforms:
        a2a:
          enabled: true
          extra:
            port: 9900
```

All other config (models, delegation, memini, mcp_servers, webapp) stays byte-identical. The init container's `envsubst` step is untouched: the new A2A values are pod env vars, not config placeholders.

### `kubernetes/apps/ai/hermes/app/helmrelease.yaml`

- `controllers.hermes.containers[app].ports` += `{containerPort: 9900, name: a2a, protocol: TCP}`.
- `controllers.hermes.containers[app].env` += non-secret values: `A2A_HOST: 0.0.0.0`, `A2A_PORT: "9900"`, `A2A_AGENT_NAME: hermes`, `A2A_PUBLIC_URL: http://hermes.ai.svc.cluster.local:9900`, `A2A_TRUSTED_PEERS: litellm`.
- `service.app.ports.a2a.port: 9900` (same chart pattern as `http`/`webapp`/`codeserver`) — internal ClusterIP only.
- No new HTTPRoute and no change to `dashboard`/`codeserver`.

### `kubernetes/apps/ai/hermes/app/externalsecret.yaml`

Add a `data` entry reading `remoteRef: {key: litellm, property: A2A_HERMES_TOKEN}` into `secretKey: A2A_HERMES_TOKEN`, and extend the target template with:

```yaml
        A2A_PEER_TOKENS: "litellm:{{ .A2A_HERMES_TOKEN }}"
```

Secret `hermes` is already injected into the `app` container via `envFrom`; no pod wiring change required. `A2A_PEER_TOKENS` provides the peer identity, so no shared `A2A_BEARER_TOKEN` (which would fall back to caller-IP identity) and no `A2A_ALLOW_ALL_USERS` are needed.

### `kubernetes/apps/ai/litellm/app/litellmproxy.yaml`

In `spec.extraConfig`, add `A2A_HERMES_TOKEN` to `environment` and a top-level `agents` catch-all key:

```yaml
  extraConfig:
    environment:
      - OPENCODE_MATT_API_KEY
      - OPENCODE_AGNES_API_KEY
      - REDIS_HOST
      - REDIS_PORT
      - A2A_HERMES_TOKEN
    agents:
      - agent_name: hermes
        agent_card_params:
          name: Hermes
          url: http://hermes.ai.svc.cluster.local:9900
          protocolVersion: "1.0"
        litellm_params:
          api_key: os.environ/A2A_HERMES_TOKEN
```

`extraConfig` is `x-kubernetes-preserve-unknown-fields` and merged at the top level of the rendered config.yaml, so `extraConfig.agents` becomes the top-level `agents:` block. No change to `litellmSettings`, model groups, teams, or virtual keys.

### `kubernetes/apps/ai/litellm/app/externalsecret.yaml`

The `dataFrom.extract` fetches the whole 1Password `litellm` item (so the new field needs no extra `data` entry), but under the default `mergePolicy: Replace` only `template.data` keys land in `litellm-secret`. Add the mapping:

```yaml
        A2A_HERMES_TOKEN: "{{ .A2A_HERMES_TOKEN }}"
```

Without it the token never reaches the proxy pods and every `/a2a/hermes` call fails upstream auth.

### `kubernetes/apps/ai/litellm/app/README.md`

Update the `agent_search` / `skill_search` section (currently says the registries are empty), document the Hermes A2A registration, the peer-token auth flow, and the manual 1Password field. Note that rotating `A2A_HERMES_TOKEN` requires restarting both workloads because env vars and the agent config are read at startup.

### 1Password (manual, before merge)

Create field `A2A_HERMES_TOKEN` in the existing **API Credential** item `litellm` in vault `home-ops`; use a freshly generated `openssl rand -hex 32` value. The implementation step supplies the exact value to paste. No PushSecret is involved: both consumers read the field through their existing 1Password-backed `ExternalSecret`s.

## Validation

1. **Local pre-push:** `mise exec -- flate test ks --path ./kubernetes/apps` and `mise exec -- flate test hr --path ./kubernetes/apps/ai/hermes`; confirm the known unrelated baseline (blocked `network/cloudflare-tunnel`, two StaleValues warnings) is unchanged. Re-check the `LiteLLMProxy.extraConfig` CRD schema (`x-kubernetes-preserve-unknown-fields`) and the Hermes chart's `service.app.ports` support.
2. **Rollout:** after merge, both Kustomizations (`ai/litellm`, `ai/hermes`) Ready; `radar-wait_for` rollout on both Deployments. Allow ~3 min for LiteLLM (MCP server connections) and the Hermes init container.
3. **Registration/discovery:** live `litellm-config` contains the `agents:` block; `agent_search` returns `hermes` for a relevant query; LiteLLM logs show the card fetch; Hermes logs show the A2A platform listening on `0.0.0.0:9900` and an answered card GET.
4. **Invocation:** an ad-hoc Job manifest (in `/tmp/opencode`, never committed) mounts `litellm-key-opencode` (`secretKey: api-key`) and POSTs a `message/send` JSON-RPC payload to `POST /a2a/hermes` with `x-litellm-api-key: Bearer $KEY`; the response text is printed in the Job logs. Confirm the matching Lens trace and the `a2a_audit.jsonl` entry. Delete the Job afterwards.
5. **Negative checks:** wrong upstream token → `401`; missing `A2A_TRUSTED_PEERS` entry would refuse dispatch (config must not regress to that); `agent_search` with the TEI model unavailable fails closed (documented in B) while direct `/a2a/hermes` still works.
6. **Non-regression:** mainclaw/devclaw configs, virtual keys and team bindings untouched; `mcp_tool_search` still returns the four virtual tools.

Known operational limits: A2A rate limit 60 req/min per identity; Hermes anti-loop cap 5 turns; token rotation requires restarts; if the card URL is wrong LiteLLM cannot fetch the card at startup and skips the agent.

## Rollback

Revert the PR → Flux restores the previous ConfigMap/HelmRelease/ExternalSecret and rolls both Deployments back; delete the ad-hoc Job. The 1Password field can remain (inert until re-enabled). No cluster-side direct edits are made, so rollback is purely GitOps.
