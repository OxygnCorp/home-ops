# LiteLLM app

This directory holds the LiteLLM proxy (`litellmproxy.yaml`, `LiteLLMProxy`), the
MCP servers proxied by it (`mcp/`), the virtual keys consumed by local agents
(`virtualkeys/` — see [virtualkeys/README.md](virtualkeys/README.md) for the
1Password conventions), and the LiteLLM teams (`teams/`) that scope MCP server
access per consumer.

Two operator CRs drive the cluster (`litellm.home-operations.com/v1alpha1`):

- `LiteLLMTeam` (`teams/`) — registers a team on the proxy and lists the MCP
  servers (`spec.mcpServers`, entries are **aliases**) its members may reach.
- `LiteLLMVirtualKey` (`virtualkeys/`) — generates a virtual key; `spec.teamID`
  binds it to a team. The operator passes the binding on key create/update in
  place (no key rotation, 1Password `KEY_*` fields unchanged).

## MCP

The MCP gateway is multiplexed by teams, mirroring the old toolhive groups:

| Team (alias) | Virtual keys | MCP servers (`spec.mcpServers`) |
| --- | --- | --- |
| `mcp-apps` | `mainclaw` | `arr`, `ha_mcp`, `seerr_mcp`, `teslamate`, `todoist_mcp`, `lightrag_mcp` |
| `mcp-devops` | `devclaw`, `opencode`, `hermes` | `context7`, `flux`, `github`, `grafana`, `konflate`, `kubectl`, `radar`, `talos_mcp`, `unifi_network` |

Notes:

- **Underscore aliases** (`ha_mcp`, `seerr_mcp`, `todoist_mcp`, `lightrag_mcp`,
  `talos_mcp`, `unifi_network`): litellm proxy ≥1.75 `validate_mcp_server_name`
  rejects `-` in server names, so hyphenated aliases became underscores.
- **`models: []` on the teams**: the operator otherwise sends `models: null` to
  `POST /team/new`, which litellm rejects with 422 `list_type`.
- **No teamID** on `foreman`, `pr-review`, `memini`, `lightrag`, `repo-wiki`
  keys: none of them consume MCP tools today (ruling 2026-10-03). They keep
  unrestricted model access only. Onboarding one later = add `spec.teamID` to
  its `virtualkeys/*.yaml` and let the operator update the remote key in place.

### Tool search default (`litellmproxy.yaml`)

`litellmSettings.default_key_generate_params.object_permission.mcp_tool_search_enabled: true`
makes every **new** key default to tool search: `tools/list` returns only the
four virtual tools (`mcp_tool_search`, `mcp_tool_call`, `agent_search`,
`skill_search`) and the LLM discovers real tools by keyword token-overlap — no
embedding model required. `/key/generate` requests that set the field
explicitly keep their value; nothing else in key generation changes.

### One-time patch for EXISTING keys

The tool-search default only reaches `/key/generate`, so the four keys that
existed before this change (`Mainclaw`, `Devclaw`, `Opencode`, `Hermes`) must be
patched once. It is one-time because the value is persisted on the key's
`object_permission` in the litellm database: from then on the *stored* state
wins and the generate-time default is irrelevant for those keys — they never
fall back to the un-searched full catalog again.

The team binding itself (`teamID`) does **not** need this patch: the operator
applies it via `/key/update` in place when it reconciles the changed CR.

Patch procedure (pod curl + master key; run from a machine with cluster access):

```bash
cd kubernetes/apps/ai/litellm/app
for k in mainclaw devclaw opencode hermes; do
  KEY=$(kubectl get secret litellm-key-$k -n ai -o jsonpath='{.data.api-key}' | base64 -d)
  kubectl run litellm-key-update-$k --rm -i --restart=Never \
    --image=curlimages/curl -n ai -- \
    curl -s -X POST http://litellm.ai.svc.cluster.local:4000/key/update \
      -H "Authorization: Bearer $MASTER_KEY" \
      -H "Content-Type: application/json" \
      -d '{"keys":["'"$KEY"'"],"object_permission":{"mcp_tool_search_enabled":true}}'
done
```

`$MASTER_KEY` is `LITELLM_MASTER_KEY` from the 1Password `litellm` item (also
mirrored into the `litellm-secret` Secret). The `keys` entries are the actual
key tokens, read from the per-key Secrets the operator generates
(`litellm-key-<name>.data.api-key`) — no alias name-matching involved.

Verify:

```bash
curl -s http://litellm.oxygn.dev/key/info?key=$KEY \
  -H "Authorization: Bearer $MASTER_KEY" |
  jq .info.object_permission.mcp_tool_search_enabled   # -> true
```

Then behavior-wise: `x-litellm-api-key: Bearer <KEY>` over `/mcp-rest/tools/list`
should return exactly the four virtual tools, and `mcp_tool_search` (e.g.
`{"query":"kubernetes logs"}`) must not surface tools outside the team's server
list.

**Re-applying on drift**: tool search can be switched off again from the Admin
UI (Keys → edit → object permission) or by another admin API call. If
`/key/info` shows `mcp_tool_search_enabled: false` on one of the four keys,
re-run the patch above — it is idempotent. Keys (re)generated from Git after
this change are already covered by the generate-time default.

### Tool exclusion (todoist `get-overview`)

`mcp/litellm-todoist-mcp` (alias `todoist_mcp`) sets
`spec.params.disallowed_tools: [get-overview]`, a server-level blacklist that
applies to **every** caller (docs: MCP Permission Management). It reproduces the
toolhive `VirtualMCPServer` aggregation exclusion
(`kubernetes/apps/ai/toolhive/config/virtualmcpserver.yaml`). A blacklist — not
an allowlist — so tools the upstream adds stay visible without a config bump.

### AuthZ probes

Verification of per-key scoping (apps-only vs devops-only lists, cross-team
search isolation, 403 on out-of-scope calls) is done post-merge by the
controller, once the teams + keys are deployed live — not from this repo's
workflows.
