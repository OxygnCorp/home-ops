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

## Admin UI SSO (Kanidm)

The Admin UI signs in through Kanidm via LiteLLM's generic OIDC provider. The
OAuth2 client is provisioned by `components/oidc-kanidm/in-app` (see
`kubernetes/apps/ai/litellm/ks.yaml`): the component adds a nested Flux
Kustomization `kanidm-litellm-oidc` (created in `ai`, `targetNamespace:
security`) that applies the `kanidm-litellm-oidc` ConfigMap in `security`;
`kanidm-provision` creates the Kanidm client `litellm` with redirect
`https://litellm.oxygn.dev/sso/callback`, and writes the Secret
`kanidm-litellm-oidc` (`client-id` / `client-secret`) in `ai`.
`litellmproxy.yaml` consumes that Secret through the `GENERIC_*` env vars.
The client uses the component's default scope map (`users` group), so the
admin must be a member of Kanidm `users`, like the other OIDC apps
(`just kanidm members users`).

### First login / admin

A new SSO user starts as `internal_user_viewer`. `PROXY_ADMIN_ID` is fetched by
the separate `litellm-admin` ExternalSecret from the `PROXY_ADMIN_ID` field of
the 1Password item `litellm` (the main `litellm` ExternalSecret uses the
default `Replace` template and only projects the keys it lists). Add the field
with the Kanidm account UUID (`sub`), then force-sync that secret:

```bash
kubectl annotate externalsecret litellm-admin -n ai force-sync=$(date +%s)
```

The reloader restarts the pods; the env reference is `optional: true`, so a
missing field does not block startup. Until the field exists,
`externalsecret litellm-admin` reports `SecretSyncedError`; that is expected
and the proxy still starts. The next SSO login promotes that user to
`proxy_admin` (LiteLLM applies `PROXY_ADMIN_ID` after creating the user and
before issuing the UI token). If the UUID is unknown, sign in once (view-only),
copy the ID from the UI, then add the field and sign in again. It can also be
read from Kanidm with `just kanidm cli person get <user>`.

Do **not** put a group name here: `PROXY_ADMIN_ID` is matched against
`GENERIC_USER_ID_ATTRIBUTE=sub`, i.e. the UUID. For multiple admins, switch to
group mapping (`GENERIC_USER_ROLE_ATTRIBUTE=groups`, a Kanidm group named
after a LiteLLM role, and `groups_name` in both `OIDC_SCOPES` in `ks.yaml` and
`GENERIC_SCOPE`) instead of adding one UUID per person.

### Free-tier / license conditions

SSO works without a license for **up to 5 users**, but the exact rule is easy
to misread:

- the limit is checked when a **new SSO user row is inserted**; existing SSO
  users keep signing in;
- the count is **every row in `LiteLLM_UserTable`** (minus SCIM-deactivated
  users), not just SSO users. Users created via `/user/new` or the UI count;
  virtual keys do **not** create user rows;
- the 6th new SSO user gets a `403` whose detail is
  `SSO for more than 5 users requires a LiteLLM Enterprise license. Existing users can still sign in.`
  (the SSO error page may wrap that detail);
- a valid `LITELLM_LICENSE` lifts the free cap. The main `litellm`
  ExternalSecret uses a `Replace` template and only projects the keys listed
  in `target.template.data`; if you have a license, fetch it with a separate
  ExternalSecret (preferred for optional fields) or add
  `LITELLM_LICENSE: "{{ .LITELLM_LICENSE }}"` to that template. A template
  entry for a missing field fails rendering (`missingkey=error`) and stalls
  the whole main sync, so only do that once the field exists.

Check the current count before relying on a free seat:

```bash
MASTER=$(kubectl -n ai get secret litellm-secret \
  -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
kubectl -n ai run litellm-users --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -s 'http://litellm.ai.svc.cluster.local:4000/user/list?page=1&page_size=100' \
  -H "Authorization: Bearer $MASTER" \
  | jq '{total: (.total // (.users | length))}'
```

### Break-glass and logout

The UI normal path is SSO: `AUTO_REDIRECT_UI_LOGIN_TO_SSO=true` sends `/ui`
to Kanidm, and `general_settings.disable_env_credential_login: true` rejects
`UI_USERNAME`/`UI_PASSWORD` and the master key on the UI login. The master key
still works as an API bearer token; `/fallback/login` is the UI break-glass.

**Before enabling `disable_env_credential_login`**, create a `proxy_admin`
database user with its own password (use an email that no SSO account uses),
test `/fallback/login`, and store the credentials in 1Password. It consumes one
of the five free seats. With the master key:

```bash
MASTER=$(kubectl -n ai get secret litellm-secret \
  -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)

curl -s -X POST https://litellm.oxygn.dev/user/new \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"user_id":"breakglass-admin","user_email":"breakglass-litellm@oxygn.dev","user_role":"proxy_admin","auto_create_key":false}'

curl -s -X POST https://litellm.oxygn.dev/user/update \
  -H "Authorization: Bearer $MASTER" -H "Content-Type: application/json" \
  -d '{"user_id":"breakglass-admin","password":"<strong-password>"}'
```

The password policy is 12+ characters with upper, lower, digit and special
characters, and it must pass LiteLLM's HaveIBeenPwned check (a strong password
found in a breach gets a 400 from `/user/update`). The inline password is for
brevity; prefer reading it from 1Password into a variable to keep it out of
shell history. From v1.104.0 an admin-set password must be changed at first
sign-in: open `/fallback/login` in a private window, set the final password and
save it in 1Password. Do not set `disable_password_login_when_sso_enabled`: it
blocks the break-glass user too. If you get locked out, the master key still
works on the API: if the break-glass row does not exist yet, `POST /user/new`
then `/user/update` (a password update alone cannot create it); if the row
exists, `/user/update` is enough. Alternatively remove
`disable_env_credential_login` from Git and reconcile.

The old env login (`UI_USERNAME`/`UI_PASSWORD` or the master key) created a
`LiteLLM_UserTable` row and counted as a seat. If it was used before this
change, that row remains; it is no longer a login path.

LiteLLM logout clears only the LiteLLM session. Kanidm has no RP-initiated
logout, so the Kanidm session survives; use `https://idm.oxygn.dev/ui/logout`
for a global logout. Setting `PROXY_LOGOUT_URL` to that URL makes the LiteLLM
logout button end the Kanidm session too (it affects every Kanidm app).

### Notes

- `GENERIC_CLIENT_USE_PKCE=true` is mandatory: Kanidm enforces PKCE even for
  confidential clients. With two LiteLLM replicas the verifier is stored in
  Redis (`redis_usage_cache`); `PKCE_STRICT_CACHE_MISS=true` makes a cache
  miss fail fast with a 401 instead of trying the exchange without
  `code_verifier`, which Kanidm would reject with `invalid_grant`.
- `PROXY_BASE_URL` must be exactly `https://litellm.oxygn.dev` (no trailing
  slash) to match the Kanidm redirect URI.
- `GENERIC_USER_DISPLAY_NAME_ATTRIBUTE=name` is required: Kanidm returns the
  display name in `name`; LiteLLM's default is `sub` (the UUID).
- The Kanidm person needs a `mail` attribute for the `email` claim; without
  it LiteLLM creates the user with a null email (email-based invites then do
  not work).
- Do not set `GENERIC_CLIENT_STATE`: with PKCE a fixed state breaks concurrent
  logins.
- The `kanidm-litellm-oidc` Secret appears asynchronously after the ConfigMap;
  pods may briefly be in `CreateContainerConfigError` until the provision
  controller writes it (kubelet retries; the reloader also restarts on Secret
  changes).
- The main `litellm` ExternalSecret uses the default `Replace` template merge
  policy: only the keys listed in `target.template.data` are written to
  `litellm-secret`. Optional values need their own ExternalSecret (as
  `litellm-admin` does for `PROXY_ADMIN_ID`) or an explicit template entry. Do
  not switch it to `mergePolicy: Merge`: that would also project every `KEY_*`
  virtual key into the proxy pod and make the pod restart on each key push.
- Removing the component/env disables SSO; the Kanidm client and the
  `kanidm-litellm-oidc` Secret may need manual cleanup.

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
- **No teamID** on `pr-review`, `memini`, `lightrag`, `repo-wiki`
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
      -d '{"key":"'"$KEY"'","object_permission":{"mcp_tool_search_enabled":true}}'
done
```

`$MASTER_KEY` is `LITELLM_MASTER_KEY` from the 1Password `litellm` item (also
mirrored into the `litellm-secret` Secret). The `key` field takes the raw
`sk-` token, read from the per-key Secret the operator generates
(`litellm-key-<name>.data.api-key`) — no alias name-matching involved. One key
per call: `UpdateKeyRequest` (litellm v1.104.0) exposes only `key: str` /
`key_alias`, there is no `keys` array — an unknown `keys` field is dropped by
Pydantic and the validator then rejects the body with 422.

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

The `litellm-todoist-mcp` CR (alias `todoist_mcp`,
`mcp/workload-wrapped.yaml`) sets
`spec.params.disallowed_tools: [get-overview]`, a server-level blacklist that
applies to **every** caller (docs: MCP Permission Management). It reproduces the
toolhive `VirtualMCPServer` aggregation exclusion
(`kubernetes/apps/ai/toolhive/config/virtualmcpserver.yaml`). A blacklist — not
an allowlist — so tools the upstream adds stay visible without a config bump.

### Footnote: `agent_search` / `skill_search`

Tool search's keyword ranking needs no embedding model — for `mcp_tool_search`
(token-overlap). The gateway also serves two other virtual tools:
`agent_search` (A2A registry) and `skill_search` (skill registry) rank by
embeddings and only work once `litellmSettings.agent_search_embedding_model` /
`skill_search_embedding_model` are set. Unused here today; configure before
relying on them.

### AuthZ probes

Verification of per-key scoping (apps-only vs devops-only lists, cross-team
search isolation, 403 on out-of-scope calls) is done post-merge by the
controller, once the teams + keys are deployed live — not from this repo's
workflows.
