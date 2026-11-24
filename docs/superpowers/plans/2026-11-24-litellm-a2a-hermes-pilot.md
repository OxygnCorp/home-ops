# LiteLLM ↔ Hermes A2A pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Register the existing Hermes gateway as an A2A agent in LiteLLM so an authenticated caller can invoke it via `POST /a2a/hermes` and discover it via `agent_search`.

**Architecture:** Declarative registration via the top-level `agents:` key in the `LiteLLMProxy` CR's `extraConfig`; Hermes exposes its native A2A v1.0 inbound platform on the cluster-internal port 9900; both sides share a peer token stored in the 1Password `litellm` item and injected through their existing 1Password-backed `ExternalSecret`s.

**Tech Stack:** Flux `HelmRelease`/`Kustomization`/`ExternalSecret`, litellm-operator CRDs, Hermes `v0.23.3` A2A platform plugin, LiteLLM `litellm-database:1.110.3`, `flate` + `yq` for local validation.

**Spec:** `docs/superpowers/specs/2026-11-24-litellm-a2a-hermes-pilot-design.md`

## Global Constraints

- Working tree: `/home/opencode/projects/home-ops-litellm-agent-search`, branch `feat/litellm-a2a-hermes-pilot` (created from `origin/main` 8fd8bc903). Never stage files other than those listed in each task.
- Hermes image is pinned to `v0.23.3@sha256:3e9fe4c6ef36490f43aa0d0d80f9df64e9c92a576eee3042f1a97c8813c05355`; do not change it.
- LiteLLM image is pinned to `1.110.3@sha256:d1ad6e7074cb4059c52af933138eb2c79839dc99b642dba81b0ffeba38e71d28`; do not change it.
- No HTTPRoute, no public ingress, no new virtual key/team, no `mainclaw`/`devclaw` change, no `A2A_BEARER_TOKEN`, no `A2A_ALLOW_ALL_USERS`.
- Secret source of truth is field `A2A_HERMES_TOKEN` in the 1Password **API Credential** item `litellm` (vault `home-ops`); never commit the token value.
- Known unrelated `flate test ks` baseline: 1 blocked (`network/cloudflare-tunnel` missing secret), 2 StaleValues warnings (`dragonfly-operator`, `envoy-gateway`). Do not try to fix them here.
- A fresh `reviewer` subagent quality pass on the final diff is mandatory before opening the PR.

---

### Task 1: Hermes inbound A2A on cluster port 9900

**Files:**
- Modify: `kubernetes/apps/ai/hermes/app/configmap.yaml:78-80`
- Modify: `kubernetes/apps/ai/hermes/app/helmrelease.yaml:83-126,195-205`
- Modify: `kubernetes/apps/ai/hermes/app/externalsecret.yaml:14-30`
- Test: `/tmp/opencode/check-a2a-hermes.sh` (throwaway, never committed)

**Interfaces:**
- Consumes: existing `hermes` ExternalSecret/Secret and `envFrom` in the `app` container.
- Produces: Service port named `a2a` on 9900 reachable at `http://hermes.ai.svc.cluster.local:9900`, card at `/.well-known/agent-card.json`, peer identity `litellm`.

- [ ] **Step 1: Write the failing check**

Create `/tmp/opencode/check-a2a-hermes.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/opencode/projects/home-ops-litellm-agent-search
CM=kubernetes/apps/ai/hermes/app/configmap.yaml
HR=kubernetes/apps/ai/hermes/app/helmrelease.yaml
ES=kubernetes/apps/ai/hermes/app/externalsecret.yaml
yq -p yaml '.data."config.yaml"' "$CM" | yq -e '.gateway.platforms.a2a.enabled == true' >/dev/null
yq -p yaml '.data."config.yaml"' "$CM" | yq -e '.gateway.platforms.a2a.extra.port == 9900' >/dev/null
yq -e '.spec.values.controllers.hermes.containers.app.ports[] | select(.name == "a2a") | .containerPort == 9900' "$HR" >/dev/null
yq -e '.spec.values.service.app.ports.a2a | has("port")' "$HR" >/dev/null
for pair in 'A2A_HOST 0.0.0.0' 'A2A_PORT 9900' 'A2A_AGENT_NAME hermes' 'A2A_PUBLIC_URL http://hermes.ai.svc.cluster.local:9900' 'A2A_TRUSTED_PEERS litellm'; do
  set -- $pair
  key="$1" value="$2" yq -e '.spec.values.controllers.hermes.containers.app.env[strenv(key)] == strenv(value)' "$HR" >/dev/null
done
yq -e '.spec.data[] | select(.secretKey == "A2A_HERMES_TOKEN") | .remoteRef.property == "A2A_HERMES_TOKEN"' "$ES" >/dev/null
yq -e '.spec.target.template.data.A2A_PEER_TOKENS == "litellm:{{ .A2A_HERMES_TOKEN }}"' "$ES" >/dev/null
echo "Hermes A2A manifest checks passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /tmp/opencode/check-a2a-hermes.sh`
Expected: non-zero exit (`yq` cannot find `.gateway.platforms.a2a`).

- [ ] **Step 3: Enable the A2A platform in the config**

In `configmap.yaml`, replace:

```yaml
    gateway:
      multiplex_profiles: false
```

with:

```yaml
    gateway:
      multiplex_profiles: false
      platforms:
        a2a:
          enabled: true
          extra:
            port: 9900
```

Do not add `A2A_*` placeholders to the config: it is rendered by `envsubst` in the init container, and these values are pod env vars.

- [ ] **Step 4: Expose port 9900 and set the A2A env in the HelmRelease**

In `helmrelease.yaml`, in `spec.values.controllers.hermes.containers.app.env`, append after the `HERMES_DASHBOARD_OIDC_CLIENT_SECRET` entry:

```yaml
              # Native A2A v1.0 inbound (Hermes >= v0.23). A non-loopback
              # bind requires both a token and A2A_HOST; A2A_PEER_TOKENS in
              # the `hermes` Secret gives LiteLLM the stable peer identity
              # "litellm" so dispatch does not depend on the caller's IP.
              A2A_HOST: 0.0.0.0
              A2A_PORT: "9900"
              A2A_AGENT_NAME: hermes
              A2A_PUBLIC_URL: http://hermes.ai.svc.cluster.local:9900
              A2A_TRUSTED_PEERS: litellm
```

In the same container's `ports` list, append after the `webapp` entry:

```yaml
              - containerPort: &a2a_port 9900
                name: a2a
                protocol: TCP
```

In `spec.values.service.app.ports`, append after `codeserver`:

```yaml
          a2a:
            port: *a2a_port
```

Keep `spec.values.route` untouched: this Service port is cluster-internal only.

- [ ] **Step 5: Inject the shared peer token via the Hermes ExternalSecret**

In `externalsecret.yaml`, in `spec.target.template.data`, append after `MEMINI_API_KEY`:

```yaml
        ## A2A peer token shared with LiteLLM (1Password `litellm` item);
        ## A2A_PEER_TOKENS maps it to the peer name "litellm".
        A2A_PEER_TOKENS: "litellm:{{ .A2A_HERMES_TOKEN }}"
```

In `spec.data`, append:

```yaml
    - secretKey: A2A_HERMES_TOKEN
      remoteRef:
        key: litellm
        property: A2A_HERMES_TOKEN
```

- [ ] **Step 6: Run the check again and validate the HelmRelease**

Run: `bash /tmp/opencode/check-a2a-hermes.sh && mise exec -- flate test hr --path ./kubernetes/apps/ai/hermes`
Expected: check prints `Hermes A2A manifest checks passed`; flate reports the Hermes HelmRelease passing with no new errors.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/ai/hermes/app/configmap.yaml \
        kubernetes/apps/ai/hermes/app/helmrelease.yaml \
        kubernetes/apps/ai/hermes/app/externalsecret.yaml
git commit -m "feat(ai/hermes): expose native A2A endpoint for LiteLLM pilot"
```

---

### Task 2: Register Hermes in LiteLLM's A2A registry

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml:344-349`
- Test: `/tmp/opencode/check-a2a-litellm.sh` (throwaway, never committed)

**Interfaces:**
- Consumes: `A2A_HERMES_TOKEN` present in Secret `litellm-secret` (populated by the existing `dataFrom.extract` on the 1Password `litellm` item).
- Produces: top-level `agents:` block in the rendered config.yaml with one entry named `hermes`, invocable at `POST /a2a/hermes`.

- [ ] **Step 1: Write the failing check**

Create `/tmp/opencode/check-a2a-litellm.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/opencode/projects/home-ops-litellm-agent-search
CR=kubernetes/apps/ai/litellm/app/litellmproxy.yaml
yq -e '.spec.extraConfig.environment[] | select(. == "A2A_HERMES_TOKEN")' "$CR" >/dev/null
yq -e '.spec.extraConfig.agents[0].agent_name == "hermes"' "$CR" >/dev/null
yq -e '.spec.extraConfig.agents[0].agent_card_params.url == "http://hermes.ai.svc.cluster.local:9900"' "$CR" >/dev/null
yq -e '.spec.extraConfig.agents[0].agent_card_params.protocolVersion == "1.0"' "$CR" >/dev/null
yq -e '.spec.extraConfig.agents[0].litellm_params.api_key == "os.environ/A2A_HERMES_TOKEN"' "$CR" >/dev/null
echo "LiteLLM A2A registration checks passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /tmp/opencode/check-a2a-litellm.sh`
Expected: non-zero exit (`A2A_HERMES_TOKEN` not in `extraConfig.environment`).

- [ ] **Step 3: Add the env var and the `agents` block**

In `litellmproxy.yaml`, replace the whole `extraConfig` block:

```yaml
  extraConfig:
    environment:
      - OPENCODE_MATT_API_KEY
      - OPENCODE_AGNES_API_KEY
      - REDIS_HOST
      - REDIS_PORT
```

with:

```yaml
  extraConfig:
    # `extraConfig` is merged verbatim into the top level of config.yaml
    # (x-kubernetes-preserve-unknown-fields). The A2A registry is a top-level
    # `agents:` key since LiteLLM v1.96 — readable even with the attached DB.
    # Config-defined agents are not editable in the UI; Git is the source of
    # truth. Hermes' card is fetched at startup from the cluster-internal URL;
    # a wrong URL means the entry is skipped, not a proxy crash.
    agents:
      - agent_name: hermes
        agent_card_params:
          name: Hermes
          url: http://hermes.ai.svc.cluster.local:9900
          protocolVersion: "1.0"
        litellm_params:
          # Sent upstream as `Authorization: Bearer <token>`; A2A agents have
          # no `auth_type` field. The token comes from the 1Password `litellm`
          # item via the existing `litellm-secret` ExternalSecret.
          api_key: os.environ/A2A_HERMES_TOKEN
    environment:
      - OPENCODE_MATT_API_KEY
      - OPENCODE_AGNES_API_KEY
      - REDIS_HOST
      - REDIS_PORT
      - A2A_HERMES_TOKEN
```

Do not add `static_headers`: it would persist the token in LiteLLM's database. Do not change `litellmSettings`, teams or virtual keys.

- [ ] **Step 4: Re-run the check and confirm the CRD accepts the key**

Run:

```bash
bash /tmp/opencode/check-a2a-litellm.sh
curl -fsSL https://k8s-schemas.home-operations.com/litellm.home-operations.com/litellmproxy_v1alpha1.json \
  | jq -e '.properties.spec.properties.extraConfig["x-kubernetes-preserve-unknown-fields"] == true'
```

Expected: check prints `LiteLLM A2A registration checks passed`; jq exits 0 (`true`).

- [ ] **Step 5: Commit**

```bash
git add kubernetes/apps/ai/litellm/app/litellmproxy.yaml
git commit -m "feat(ai/litellm): register Hermes as an A2A agent"
```

---

### Task 3: Document the pilot and hand over the 1Password token

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/README.md:292-301`
- Test: `/tmp/opencode/check-a2a-readme.sh` (throwaway, never committed)

**Interfaces:**
- Consumes: Task 2's `agents:` block and Task 1's `A2A_PEER_TOKENS`.
- Produces: operator-facing runbook for the pilot and rotation; a token to paste into 1Password before merge.

- [ ] **Step 1: Write the failing check**

Create `/tmp/opencode/check-a2a-readme.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
cd /home/opencode/projects/home-ops-litellm-agent-search
README=kubernetes/apps/ai/litellm/app/README.md
grep -q 'POST /a2a/hermes' "$README"
grep -q 'A2A_HERMES_TOKEN' "$README"
grep -q 'openssl rand -hex 32' "$README"
echo "A2A README checks passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash /tmp/opencode/check-a2a-readme.sh`
Expected: non-zero exit (no `/a2a/hermes` mention).

- [ ] **Step 3: Generate the peer token for the operator**

Run: `python3 -c 'import secrets; print(secrets.token_hex(32))'` (the executor's shell has no `openssl`; the README keeps the generic `openssl rand -hex 32` wording for operators).

Copy the printed 64-hex-character value into the chat reply to the user with this instruction: create field `A2A_HERMES_TOKEN` in the 1Password item `litellm` (vault `home-ops`, API Credential) **before merging**, using that value. Never write it into a file or commit message.

- [ ] **Step 4: Extend the README section**

In `README.md`, replace the whole `### agent_search / skill_search embedding models` section (lines 292-301) with:

```markdown
### `agent_search` / `skill_search` embedding models

Tool search's keyword ranking needs no embedding model — for `mcp_tool_search`
(token-overlap). The gateway's two other virtual tools — `agent_search` (A2A
registry) and `skill_search` (skill registry) — rank by embeddings and need
`litellmSettings.agent_search_embedding_model` / `skill_search_embedding_model`.
Both are pinned to `qwen3-embedding-0.6b`, the same local TEI model as
`mcp_semantic_tool_filter`, so the two tools answer on every key with tool
search enabled — no longer 400.

`agent_search` currently ranks one registered agent: `hermes`. The
declarative `extraConfig.agents[]` entry makes LiteLLM fetch Hermes' A2A card
from `http://hermes.ai.svc.cluster.local:9900/.well-known/agent-card.json`
at startup; invoke it with `POST /a2a/hermes` (JSON-RPC `message/send`) using
`x-litellm-api-key: Bearer <KEY>`. LiteLLM forwards
`Authorization: Bearer <A2A_HERMES_TOKEN>` upstream; Hermes maps that token to
the peer name `litellm` via `A2A_PEER_TOKENS` and accepts only that peer via
`A2A_TRUSTED_PEERS`. The 1Password `litellm` item must contain field
`A2A_HERMES_TOKEN` (`openssl rand -hex 32`) **before merge** — otherwise both
ExternalSecrets stay out of sync. Rotating it requires restarting both
workloads: the agent config and the peer token are read at startup.
```

- [ ] **Step 5: Run the check**

Run: `bash /tmp/opencode/check-a2a-readme.sh`
Expected: `A2A README checks passed`.

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/ai/litellm/app/README.md
git commit -m "docs(ai/litellm): document Hermes A2A pilot and token rotation"
```

---

### Task 4: Full validation, quality pass, and dedicated PR

**Files:** none (branch-level deliverable)

**Interfaces:**
- Consumes: commits from Tasks 1–3.
- Produces: PR against `origin/main` with all three commits, plus the handoff steps for post-merge live validation.

- [ ] **Step 1: Run full local validation**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps/ai/hermes
bash /tmp/opencode/check-a2a-hermes.sh
bash /tmp/opencode/check-a2a-litellm.sh
bash /tmp/opencode/check-a2a-readme.sh
```

Expected: 103 passed / 1 blocked (pre-existing `network/cloudflare-tunnel`) / 2 StaleValues warnings; all three checks pass. Any new failure blocks the PR.

- [ ] **Step 2: Dispatch the mandatory fresh-context reviewer**

Dispatch a `reviewer` subagent with the modified file list and the goal (Hermes A2A pilot registered in LiteLLM), **not** with this plan's reasoning. Ask it for remaining bugs, edge cases, error handling and QoL wins. Fix any findings, re-run Step 1, and amend or add commits as needed.

- [ ] **Step 3: Push and open the PR**

```bash
git push -u origin feat/litellm-a2a-hermes-pilot
gh pr create --title "feat(ai): pilot LiteLLM A2A broker with Hermes" \
  --body-file /tmp/opencode/a2a-pr-body.md
```

Write `/tmp/opencode/a2a-pr-body.md` first with: Summary (Hermes A2A inbound + LiteLLM registry + peer token + docs), **manual pre-merge step** (create `A2A_HERMES_TOKEN` in 1Password `litellm` item with the value provided in chat), Validation (flate results + checks + reviewer outcome), and Post-merge plan (rollout, `agent_search`, ad-hoc Job `message/send`, Lens trace, rollback = revert PR + delete Job).

- [ ] **Step 4: Hand off post-merge verification**

Do not merge the PR yourself. After merge, verify with the cluster-side MCP tools: both Kustomizations Ready, both rollouts complete, live `litellm-config` has the `agents:` block, `agent_search("Hermes gateway")` returns the agent, then run the ephemeral Job from the spec and check Lens/`a2a_audit.jsonl`.

## Post-merge verification detail (not part of this PR)

- Job: namespace `ai`, image `curlimages/curl`, mount Secret `litellm-key-opencode` (`secretKey: api-key`), POST to `http://litellm.ai:4000/a2a/hermes` with headers `Content-Type: application/json`, `x-litellm-api-key: Bearer $(cat /var/run/secrets/key/api-key)`, body:

```json
{"jsonrpc":"2.0","id":1,"method":"message/send","params":{"message":{"role":"user","parts":[{"kind":"text","text":"Bonjour, confirmes-tu que tu réponds via A2A ?"}]}}}
```

- Expected: JSON-RPC result with a text part from Hermes; matching trace in Lens; one line in Hermes' `a2a_audit.jsonl`. Delete the Job afterwards.
- Negative probes: wrong upstream token → 401; card URL unreachable → agent skipped at startup; TEI down → `agent_search` fails closed while `/a2a/hermes` still works.
- Rollback: revert the PR, Flux restores both workloads; delete the ad-hoc Job. The 1Password field can remain inert.
