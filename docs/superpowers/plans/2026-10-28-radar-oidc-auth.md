# Radar OIDC (Kanidm) + Identity-aware MCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Protect Radar (browser + MCP endpoints) behind Kanidm SSO via an Envoy Gateway `SecurityPolicy` that forwards a scalar identity header (`X-Forwarded-User`), with Radar running in `auth.mode: proxy`, and a dedicated MCP identity injected by LiteLLM so headless agents keep working.

**Architecture:** Radar is exposed via `HTTPRoute radar` to the `envoy-internal` gateway. We add an OIDC `SecurityPolicy` (Kanidm provider) on that HTTPRoute: Envoy terminates the browser OIDC flow, then a JWT provider extracts the ID token from the (pinned) cookie and maps the scalar `email` claim to `X-Forwarded-User`, which Radar in `proxy` auth mode uses as the user identity. MCP clients reach Radar in-cluster (`http://radar.radar:9280/mcp`, never through the gateway), so they bypass Envoy entirely and get identity from a `static_headers` param on the `LiteLLMMCPServer`. A kanidm-provision ConfigMap (existing component `oidc-kanidm/base`) declaratively creates the Kanidm OAuth2 client and the `kanidm-radar-oidc` Secret.

**Tech Stack:** Flux (Kustomization + kustomize components), Envoy Gateway v1.9 `gateway.envoyproxy.io/v1alpha1` `SecurityPolicy` (`oidc` + `jwt.providers` + `claimToHeaders`), Kanidm + kanidm-provision, LiteLLM operator CRD `LiteLLMMCPServer`, `flate` for local validation, konflate for PR-rendered diffs.

**Spec:** No separate spec doc; design decisions are the research conclusions recorded in this plan's **Global Constraints** and in `kubernetes/components/oidc-kanidm/README.md`.

## Global Constraints

- Repo-wide: HelmRelease namespace is never set inline — kustomize `namespace:` from the app `kustomization.yaml` injects it; `spec.targetNamespace` is set directly in each app's `ks.yaml`. Reviewers must not flag it.
- All secrets via external-secrets/1Password **except** the per-app OIDC secret: `kanidm-${APP}-oidc` (keys `client-id` / `client-secret`) is created by the kanidm-provision controller in the app's namespace — never hand-write it or add a 1Password item.
- The `oidc-kanidm` component root (`kubernetes/components/oidc-kanidm`) = `base/` only (Flux KS `kanidm-${APP}-oidc` + kanidm-provision ConfigMap). The `envoy/` sub-component does **not** support the JWT provider fields we need, so the `SecurityPolicy` lives in the app dir instead — **Task 3** uses the root component + a hand-written SecurityPolicy in the same app dir.
- Flux `postBuild.substitute` values apply to *everything* built by the KS, including manifests in the app dir — this is why `${APP}` / `${DOMAIN}` / `${SUBDOMAIN}` work in the SecurityPolicy YAML (same mechanism as the components). Gotcha: any `${VAR}` present in an app-dir manifest but **not** in the substitute map renders as an **empty string** (envsubst drops undefined), so the substitute set on `radar/ks.yaml` is load-bearing for these files.
- Envoy Gateway v1.9 facts (verified against gateway.envoyproxy.io/v1.9 docs + upstream testdata):
  - `oidc.cookieNames.idToken` **must be pinned** — without it the cookie suffix is random and the JWT provider cannot extract it deterministically.
  - Envoy's oauth2 filter **encrypts** token cookies by default (HMAC/AES with the `envoy-oidc-hmac` secret) — the JWT provider would read ciphertext, not a JWT, and reject every authenticated request with 401. `oidc.disableTokenEncryption: true` is therefore **required** in this design (trade-off documented in Task 3 and in the PR: the ID token sits in the cookie as a plaintext-but-HttpOnly JWT).
  - `claimToHeaders` claims of **array type are not supported** → the `groups` claim can NOT become `X-Forwarded-Groups`. Radar therefore gets a per-user identity, never groups from this chain.
  - OAuth2 filter runs before the JWT provider in the filter chain; `jwt.optional: true` maps to Envoy's `allow_missing` — a **missing** token (e.g. `/oauth2/callback` and `/logout` requests that legitimately lack the ID-token cookie yet are still their browser session) is tolerated through the JWT provider, while an **invalid** token still 401s. Defense stays layered: radar itself rejects unauthenticated requests in `proxy` mode.
  - EG v1.9.3 `RemoteJWKS` supports `uri`, `cacheDuration` (default `300s`) and `failedRefetchDuration` (default `1s`) — there is **no** `reloadDuration` field in this CRD.
  - Pinned endpoints pattern (from the component + README): alias/token endpoints pinned so EG never re-discovers through the gateway during Kanidm TLS rollouts.
- Kanidm facts: issuer `https://idm.oxygn.dev/oauth2/openid/<client>`, `authorization_endpoint https://idm.oxygn.dev/ui/oauth2`, `token_endpoint https://idm.oxygn.dev/oauth2/token`, `jwks_uri https://idm.oxygn.dev/oauth2/openid/<client>/public_key.jwk` (verified live on the `mainclaw` config); signing alg ES256; scopes `groups` exposes UUID+SPN claims; **no `end_session_endpoint`** in discovery → Radar's OIDC logout falls back to `prompt=login` (known upstream limitation, issues kanidm #3752/#1997/#4240 — documented, not fixable here).
- Kanidm refresh tokens default to a **16h sliding expiry**; extend to 7d (`oauth2_refresh_token_expiry: ["604800"]`) per client via the API — not part of the provision schema, manual step **Task 6**; re-apply if the client is re-provisioned or the DB restored.
- Radar facts (chart 1.18.3, skyhook-io/radar v0.13.x docs + `middleware.go`): auth modes `none|proxy|oidc`; `proxy` mode trusts `X-Forwarded-User` (and would read `X-Forwarded-Groups`); paths under `/mcp*`, `/mcp-readonly`, `/mcp-apply` require authentication in both `oidc` and `proxy` modes; only `/api/health`, `/auth/*` and non-`/api|/mcp|/debug` paths are exempt. There is **no** bearer-token auth in the OSS build.
- MCP clients (LiteLLM → headless agents) call Radar in-cluster (`http://radar.radar:9280/mcp`), never through the gateway → they skip Envoy entirely; identity comes from a `static_headers` param on `LiteLLMMCPServer` (schema `litellm.home-operations.com/litellmmcpserver_v1alpha1`: `spec.params` is a passthrough object merged under the typed CRD fields). LiteLLM (v1.106.5, the deployed version) `mcp_servers` semantics: `static_headers: dict[str,str]` = concrete headers **always sent** upstream; `extra_headers: list[str]` = names of headers forwarded from the incoming client request — NOT a dict. The plan therefore uses `static_headers`.
- Known accepted risk (document in PR): with `proxy` mode Radar trusts `X-Forwarded-User` from any in-cluster caller that can reach `radar.radar:9280`. The repo has zero `NetworkPolicy` usage (verified), so adding one here would be a one-off; noted as a hardening follow-up, out of scope.
- Validation gate: `mise exec -- flate test ks --path ...` / `flate test hr ...` before every push; konflate posts the rendered diff on the PR.

---

### Task 1: Wire the oidc-kanidm component into the radar Kustomization

**Files:**
- Modify: `kubernetes/apps/radar/radar/ks.yaml`

**Interfaces:**
- Consumes: component `kubernetes/components/oidc-kanidm` (root = `base/`), substitution variables from `base/ks.yaml`.
- Produces: Flux KS `kanidm-radar-oidc` (created in the **consumer's namespace `radar`**, with `spec.targetNamespace: security`) which applies the `ConfigMap kanidm-radar-oidc` in `security` (label `kanidm_config: "1"`) → the kanidm-provision controller PATCHes Kanidm to create the OAuth2 client and writes Secret `kanidm-radar-oidc` (keys `client-id` / `client-secret`) in namespace `radar`. Later tasks consume those names exactly.

- [ ] **Step 1: Edit `kubernetes/apps/radar/radar/ks.yaml`** to add the component, the kanidm dependency, and the OIDC substitutes. Keep the existing kopiur bits untouched. Full target content:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: radar
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: radar
  components:
    - ../../../../components/kopiur/backup
    - ../../../../components/oidc-kanidm
  dependsOn:
    - name: kanidm
      namespace: security
    - name: kopiur
      namespace: kopiur-system
  interval: 1h
  path: ./kubernetes/apps/radar/radar/app
  postBuild:
    substitute:
      APP: radar
      APP_NAMESPACE: radar
      DOMAIN: oxygn.dev
      KOPIUR_CAPACITY: 5Gi
      KOPIUR_PUID: "65532"
      KOPIUR_PGID: "65532"
      OIDC_CALLBACK: /oauth2/callback
      OIDC_DISPLAY_NAME: Radar
      OIDC_ROUTE_NAME: radar
      SUBDOMAIN: radar
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: radar
  wait: false
```

Notes: `OIDC_CALLBACK` is `/oauth2/callback` (Envoy's default redirect path — the browser flow is terminated by Envoy, NOT by radar; the later SecurityPolicy uses the same literal). `OIDC_ROUTE_NAME` is unused by `base/` (it's an `envoy/`-only variable) but harmless and keeps the substitute set complete.

- [ ] **Step 2: Validate locally**

Run: `mise exec -- flate test ks --path ./kubernetes/apps/radar/radar`
Expected: PASS (builds clean, no null substitutions).

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/radar/radar/ks.yaml
git commit -m "feat(radar): wire kanidm OIDC client provision component"
```

---

### Task 2: Switch Radar to `auth.mode: proxy`

**Files:**
- Modify: `kubernetes/apps/radar/radar/app/helmrelease.yaml` (values: `auth` block)

**Interfaces:**
- Consumes: nothing.
- Produces: Radar accepts `X-Forwarded-User` (and `X-Forwarded-Groups`) as the request identity; the `auth.secret` HMAC session machinery of `oidc` mode is unused.

- [ ] **Step 1: Edit the `auth` block in the HelmRelease values**

Find the existing block (it currently reads `auth: ... mode: none` inside `values:`) and change to:

```yaml
  auth:
    mode: proxy
```

Do NOT add `auth.secret` — proxy mode is stateless (no radar cookie signing).

- [ ] **Step 2: Validate locally**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/radar/radar/app`
Expected: PASS.

- [ ] **Step 3: Diff against baseline to confirm only the auth change lands**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps/radar --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps/radar --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: diff shows the `kanidm-radar-oidc` Kustomization (Task 1) and `auth.mode: proxy` only.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/radar/radar/app/helmrelease.yaml
git commit -m "feat(radar): auth mode none -> proxy (identity via X-Forwarded-User)"
```

---

### Task 3: OIDC `SecurityPolicy` on the radar HTTPRoute (browser path)

**Files:**
- Create: `kubernetes/apps/radar/radar/app/securitypolicy.yaml`
- Modify: `kubernetes/apps/radar/radar/app/kustomization.yaml`

**Interfaces:**
- Consumes: HTTPRoute `radar` (existing, unchanged) in namespace `radar`; Secret `kanidm-radar-oidc` (Task 1, created by the provision controller).
- Produces: `SecurityPolicy radar-oidc` — browser sessions to `radar.oxygn.dev` are OIDC-protected by Kanidm; authenticated requests carry header `X-Forwarded-User: <email>`. This is the only SecurityPolicy in the app dir; do NOT include the `envoy/` sub-component.

- [ ] **Step 1: Create `securitypolicy.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/securitypolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: radar-oidc
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: radar
  oidc:
    provider:
      issuer: https://idm.oxygn.dev/oauth2/openid/${APP}
      # Endpoints pinned explicitly: Envoy Gateway does not retry a failed
      # discovery (Kanidm TLS certificate rollouts would wedge auth).
      authorizationEndpoint: https://idm.oxygn.dev/ui/oauth2
      tokenEndpoint: https://idm.oxygn.dev/oauth2/token
      clientID: ${APP}
      clientSecret:
        name: kanidm-${APP}-oidc
      scopes:
        - openid
        - profile
        - email
      # Required: the oauth2 filter encrypts token cookies by default; the
      # JWT provider below must read the raw JWT out of the cookie.
      disableTokenEncryption: true
      cookieNames:
        idToken: radar-id-token
    redirectURL: https://${SUBDOMAIN}.${DOMAIN}/oauth2/callback
    logoutPath: /logout
    defaultRefreshTokenTTL: 168h
  jwt:
    optional: true
    providers:
      - name: kanidm-radar
        issuer: https://idm.oxygn.dev/oauth2/openid/${APP}
        remoteJWKS:
          uri: https://idm.oxygn.dev/oauth2/openid/${APP}/public_key.jwk
        extractFrom:
          cookies:
            - radar-id-token
        claimToHeaders:
          - claim: email
            header: X-Forwarded-User
```

Why these exact choices:
- `targetRefs` (plural list form, like every SecurityPolicy already in the repo) — the singular `targetRef` is deprecated in EG v1.9 (deprecation warning in status).
- `cookieNames.idToken` pinned → the JWT provider can extract the cookie deterministically (unpinned = random suffix).
- `disableTokenEncryption: true` → without it Envoy stores the ID token **encrypted** in the cookie and the JWT provider (`extractFrom.cookies`) reads ciphertext, rejecting every authenticated browser request with 401. Trade-off to document in the PR: the ID token now sits in the cookie as a raw (HttpOnly, SameSite) JWT instead of ciphertext — it is short-lived, verifiable with the pinned JWKS by anyone it was sent to anyway, and scoped to `openid profile email` for this app only.
- JWT provider mirrors the OIDC issuer, so the ID token signature/audience is validated by Envoy via the pinned Kanidm JWKS, not by Radar.
- `remoteJWKS`: only `uri` — `cacheDuration` defaults to `300s` and `failedRefetchDuration` to `1s` in v1.9.3; there is no `reloadDuration` field in this CRD.
- `scopes`: no `groups` — the claim would arrive anyway via the claim maps, but `claimToHeaders` cannot map an array claim (Envoy Gateway limitation: "Array type claims are not supported"). Radar is per-user; record the RBAC follow-up in the PR instead of pretending groups work.
- `jwt.optional: true`: the oauth2 filter runs BEFORE the JWT provider, so by the time a normal `/` or `/api/*` request reaches the JWT provider its `radar-id-token` cookie exists — what `optional` actually protects are the callback (`/oauth2/callback`) and logout requests that traverse the route without an ID-token cookie. A *missing* token is then tolerated (Envoy `allow_missing`), an *invalid* one still 401s, and radar's `proxy` mode keeps rejecting headerless requests at the app layer.
- Also worth noting in the PR: the capability pairing (OIDC + JWT provider with cookie extraction + `disableTokenEncryption`) is new to this repo — the component `envoy/` SecurityPolicy has no JWT provider, so future users should copy from this file; drop a line in `kubernetes/components/oidc-kanidm/README.md` as part of this PR's commit list.

- [ ] **Step 2: Add it to the app kustomization** — `kubernetes/apps/radar/radar/app/kustomization.yaml` becomes:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrepository.yaml
  - ./helmrelease.yaml
  - ./httproute.yaml
  - ./securitypolicy.yaml
```

- [ ] **Step 3: Validate locally**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/radar/radar/app`
Expected: PASS (substitutions `${APP}`/`${SUBDOMAIN}`/`${DOMAIN}` expand from the KS postBuild — same mechanism as the manifest dir on other apps).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/radar/radar/app/securitypolicy.yaml \
        kubernetes/apps/radar/radar/app/kustomization.yaml
git commit -m "feat(radar): kanidm OIDC SecurityPolicy on browser HTTPRoute (envoy-internal)"
```

---

### Task 4: Dedicated MCP identity via LiteLLM

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/mcp/remote.yaml` (only the `radar` document)

**Interfaces:**
- Consumes: Task 2 (`proxy` mode at radar) — the header is the whole identity.
- Produces: every MCP client hitting LiteLLM's `radar` alias presents header `X-Forwarded-User: radar-mcp@oxygn.dev` to the in-cluster radar endpoint.

- [ ] **Step 1: Edit the `radar` entry in `remote.yaml`** (leave grafana/konflate/teslamate untouched). Target content of that document:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/litellm.home-operations.com/litellmmcpserver_v1alpha1.json
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMMCPServer
metadata:
  name: radar
spec:
  alias: radar
  proxyRef: litellm
  url: http://radar.radar:9280/mcp
  transport: http
  params:
    static_headers:
      X-Forwarded-User: radar-mcp@oxygn.dev
```

`spec.params` is the CRD's passthrough object (merged under the typed fields); the operator passes it verbatim into the litellm `mcp_servers` entry. In litellm v1.106.5 (the deployed image) `static_headers: dict[str,str]` means "always send this header upstream" — which is exactly the dedicated-identity semantics needed. Do NOT use `extra_headers` (it is `list[str]`, a list of header *names* to forward from the incoming client request, not a mapping) — a dict there is invalid/unpredictable. There is no other candidate key: this is decided by the upstream types, not by Task 6 evidence; Task 6 still verifies it reached the wire.

- [ ] **Step 2: Validate locally**

Run: `mise exec -- flate test ks --path ./kubernetes/apps/ai/litellm`
Expected: PASS. (The `LiteLLMMCPServer` is a raw manifest under the app dir rendered by the Kustomization build, not part of a HelmRelease — `flate test hr` cannot see it.)

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/ai/litellm/app/mcp/remote.yaml
git commit -m "feat(litellm): send X-Forwarded-User identity for radar MCP"
```

---

### Task 5: Full pre-push validation

**Files:** none (verification only)

- [ ] **Step 1: Validate everything touched**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps/radar
mise exec -- flate test ks --path ./kubernetes/apps/ai/litellm
```
Expected: all PASS.

- [ ] **Step 2: Diff both apps against origin/main**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps/radar --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps/radar --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff ks --path ./kubernetes/apps/ai/litellm --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: only the intended deltas (Task 1-4). Note: the Task 4 change is only visible in the `ks` diff (raw manifest in the KS build), not in a `hr` diff.

- [ ] **Step 3: Push branch, open PR**

Expected: konflate PR check renders the same objects successfully.

---

### Task 6: Live verification + Kanidm client hardening (post-merge)

**Files:** none (runtime only; recorded in this plan's checkboxes and the PR)

- [ ] **Step 1: Confirm provision ran** (NOTE: the nested KS is created in the **consumer's ns `radar`**; only the ConfigMap lands in `security`):

```bash
kubectl get kustomization -n radar kanidm-radar-oidc
kubectl get configmap -n security kanidm-radar-oidc
kubectl get secret -n radar kanidm-radar-oidc
```
Expected: KS Ready; Secret with `client-id` / `client-secret`.

Race warning (do this unconditionally, not only on failure): `dependsOn: kanidm`(the parent-vs-provisioner ordering) does **NOT** order "Secret `kanidm-radar-oidc` exists" against the SecurityPolicy translation — the Secret is written out-of-band by the kanidm-provision controller after the ConfigMap applies, and EG will likely translate the SecurityPolicy first (rejection condition, no auth filter attached: radar in `proxy` mode then answers 401/redirect everywhere). EG should auto-recover when the Secret appears (it watches Secrets), but the component README documents the nudge as empirically needed — so right after the first reconciliation, force a clean re-translation and check the status:

```bash
kubectl annotate securitypolicy radar-oidc -n radar \
  konflate.oxygn.dev/noop-retranslate=$(date +%s)
kubectl describe securitypolicy radar-oidc -n radar
```
Expected: no `secret-not-found` condition; the OIDC filter is reported as attached.

- [ ] **Step 2: Extend refresh-token expiry to 7d (manual, out-of-band)** — same command as used for mainclaw/opencode (README, applied for those two on 2026-10-27):

```bash
kubectl port-forward -n security svc/kanidm 8443:8443 &
PF_PID=$!
TOKEN=$(kubectl get secret -n security kanidm-provision-token -o jsonpath='{.data.token}' | base64 -d)
curl -sk -X PATCH \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"attrs": {"oauth2_refresh_token_expiry": ["604800"]}}' \
  https://localhost:8443/v1/oauth2/radar
kill $PF_PID
```
Expected: 200-ish response; verify with a subsequent client GET (`curl -sk -H "Authorization: Bearer $TOKEN" https://localhost:8443/v1/oauth2/radar | jq '.attrs.oauth2_refresh_token_expiry'` → `["604800"]`).

- [ ] **Step 3: Browser path** — open `https://radar.oxygn.dev` in a browser.
  Expected: redirect to `https://idm.oxygn.dev/ui/oauth2` (Kanidm login), then back to `https://radar.oxygn.dev/oauth2/callback` → Radar UI at 200. In the backend logs / audit trail, the identified user should be your Kanidm account email (scalar `email` claim → `X-Forwarded-User`). Radar's logout button: expect it to merely prompt re-login (Kanidm exposes no `end_session_endpoint` — known limitation, not fixable here).
  Failure path: "logged in, then bounced" (OIDC succeeds but radar answers 401) means the ID token had no `email` claim → check the user's Kanidm group membership: scopes are granted via the scope map for the `users` group (`OIDC_GROUP`, default), so an account outside that group gets no `email` claim, and `claimToHeaders` then emits nothing. Also confirm the account has a primary email set (`kanidm person update`).

- [ ] **Step 4: MCP endpoints protect themselves at the gateway** — from outside (LAN):

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://radar.oxygn.dev/mcp
```
Expected: `401` (or a 302 redirect to the OIDC login, per Envoy's unauthenticated response for that filter — both prove auth is active). Before the change it answered `200` anonymously. Note: the oauth2 filter sits at the gateway in front of every radar path, so even `/api/health` now answers 302/401 through `https://radar.oxygn.dev` (radar's own exemption list only applies once a request reaches the app). If external monitors probe that URL, either move them in-cluster/target the Service, or accept the noise explicitly in the PR (`oidc.denyRedirect` on the SecurityPolicy would return 401 JSON instead of a redirect for AJAX probes).

- [ ] **Step 5: MCP path through LiteLLM** — exercise the `radar` MCP alias from an mcp-devops client (OpenCode / devclaw / hermes toolchain) or directly against the LiteLLM proxy:

```bash
# smoke: does the in-cluster route answer with identity?
kubectl run radar-mcp-test --rm -it --restart=Never \
  --image=curlimages/curl -n radar -- \
  curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'X-Forwarded-User: radar-mcp@oxygn.dev' \
  http://radar.radar:9280/mcp
```
Expected: a protocol-level response (`426`, `400`, or `405` from the MCP handler are fine — anything but `401` proves the header is honored). Then use the litellm `radar` alias end-to-end (agent calls a radar MCP tool) and confirm radar logs show `radar-mcp@oxygn.dev`. If the alias still gets 401 while the direct smoke test works, check the litellm proxy logs for the rendered `mcp_servers` entry (`static_headers` present?) before touching anything else — the upstream types leave no alternate key.

- [ ] **Step 6: Record outcomes** in the PR: which HTTP code each check returned, and the accepted-risk notes: (a) in-cluster callers can spoof `X-Forwarded-User` (no NetworkPolicies repo-wide; candidate hardening follow-up), (b) the ID token is stored unencrypted (HttpOnly) in the `radar-id-token` cookie because of `disableTokenEncryption: true`, (c) previously-anonymous `/api/health` probes through the gateway now get intercepted by OIDC.

---

## Self-review performed (by plan author)

- **Spec coverage:** browser auth (Task 3), app auth mode (Task 2), client provision (Task 1), MCP identity (Task 4), validation gates (Task 5), kanidm refresh + runtime proving (Task 6 + constraint list). Kanidm logout limitation and groups-claim limitation are documented, not silently dropped. Component-README addition for the OIDC+JWT pairing is included in Task 3.
- **Placeholder scan:** every YAML block is complete; all field names verified against Envoy Gateway v1.9.3 (`targetRefs`, `disableTokenEncryption`, `RemoteJWKS.uri` only) and litellm v1.106.5 types (`static_headers: dict[str,str]`); no runtime-decided key left ambiguous.
- **Type/name consistency:** Secret `kanidm-radar-oidc` (Task 1 produces, Task 3 consumes, Task 6 checks); cookie `radar-id-token` (Task 3 sets `oidc.cookieNames.idToken`, reads `extractFrom.cookies`, Task 6 explains); identity `radar-mcp@oxygn.dev` (Task 4, Task 6).
