# Radar AllowedHosts (no-auth stays) Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After the radar chart upgrade (1.18.3) refused to serve without authentication (`Radar without authentication answers only localhost, IP addresses, Kubernetes Service names and hosts in --allowed-hosts ...`), keep radar on `auth.mode: none` and satisfy the DNS-rebinding protection by listing the public hostname in the chart's `allowedHosts` value. OIDC is explicitly deferred.

**Architecture:** One HelmRelease values change (4 lines). The chart builds `--allowed-hosts` from its own `allowedHosts` value plus chart-managed route hosts only (the repo's `HTTPRoute radar` is a standalone manifest, so the hostname must be listed manually). Envoy terminates `https://radar.oxygn.dev` and the `HTTPRoute` preserves the `Host` header, while the check stays active (no `"*"`). Rendered arg (verified via `helm template radar` from the 1.18.3 chart): `--allowed-hosts=radar.radar,radar.oxygn.dev,radar.example.com` (`radar.example.com` is the inert chart default `ingress.hosts` entry, already present today).

**Tech Stack:** Flux HelmRelease (chart radar 1.18.3 from `https://skyhook-io.github.io/helm-charts/`), `flate` for local validation, konflate for PR-rendered diffs.

**Spec:** User decision `restons sur du no auth pour l'instant alors` (2026-10-28). The previous OIDC+Kanidm plan (browser SSO + identity-aware MCP, per-user `X-Forwarded-User`) is preserved in git history at commit `0e88d1849` (`docs/superpowers/plans/2026-10-28-radar-oidc-auth.md`) and can be revived verbatim when authentication is desired.

## Global Constraints

- Chart semantics verified against `skyhook-io/helm-charts radar@1.18.3` (values.yaml + `tests/deployment_allowed_hosts_test.yaml`):
  - `allowedHosts` is a **top-level** value (`allowedHosts: []`), list of hostnames only — a scheme or port (`https://radar.example.com:8443`) fails the template; wildcards (`*.example.com`) and `"*"` (output truncation guard) are passed through. `"*"` turns the check off — do NOT use it.
  - The rendered `--allowed-hosts` always contains `radar.radar` (the Service's namespace-qualified name is derived as `<fullname>.<release-namespace>`).
  - The chart only auto-adds `ingress.hosts` / `httpRoute.hostnames` when it renders that route itself (`httpRoute.enabled: true`, which **fails if `ingress.enabled: true`**). In this repo the `HTTPRoute radar` is a standalone manifest (`kubernetes/apps/radar/radar/app/httproute.yaml`)while the HelmRelease sets `ingress.enabled: true` (which renders a chart Ingress, pre-existing, out of scope) — therefore the public hostname must be listed manually in `allowedHosts`.
- `trustedOrigins` stays empty: Envoy Gateway does not rewrite the `Host` header on `HTTPRoute` passthrough, so the default origin handling is fine.
- Repo conventions: no inline namespace on the HelmRelease (injected by app `kustomization.yaml`); no 1Password/external-secrets changes needed; never touch unrelated values.
- Security trade-off to state in the PR (accepted by user decision): with `auth.mode: none`, every caller on the internal network that can `https://radar.oxygn.dev` gets radar's (broad) RBAC — hostname checking only blocks CSS/DNS-rebinding style attacks, not access control. Revival path: the archived OIDC plan.
- Validation gate: `flate test hr` + `flate diff hr` before push; konflate renders on the PR.

---

### Task 1: Add `allowedHosts` to the radar HelmRelease

**Files:**
- Modify: `kubernetes/apps/radar/radar/app/helmrelease.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: deployment arg `--allowed-hosts=radar.radar,radar.oxygn.dev`.

- [ ] **Step 1: Edit `kubernetes/apps/radar/radar/app/helmrelease.yaml`** — inside `spec.values`, add the top-level `allowedHosts` key just under the `ingress` block:

```yaml
    ingress:
      enabled: true

    allowedHosts:
      - radar.oxygn.dev
```

(Indentation: 4 spaces — sibling of `ingress:` and `auth:` in `spec.values`.)

- [ ] **Step 2: Validate locally**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/radar/radar/app`
Expected: PASS.

- [ ] **Step 3: Diff against baseline to confirm only this change lands**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff hr --path ./kubernetes/apps/radar --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: the only delta is `--allowed-hosts` gaining `radar.oxygn.dev` in the Deployment args (`radar.example.com` was already there from the chart's default `ingress.hosts`).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/radar/radar/app/helmrelease.yaml
git commit -m "fix(radar): allow radar.oxygn.dev in expected hosts (no-auth mode)"
```

---

### Task 2: Full pre-push validation + PR

**Files:** none (verification only)

- [ ] **Step 1: Validate the whole repo KS build is untouched**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps/radar
```
Expected: all PASS.

- [ ] **Step 2: Push branch, open PR**

PR description must state: root cause (chart 1.18 hardened `--allowed-hosts`; our hostname was never auto-detected because the HTTPRoute is a standalone manifest, not chart-managed `httpRoute.*`), the single-line fix, and the accepted security trade-off (no auth=none access control; OIDC plan kept in git history at `0e88d1849` for when identity is wanted).

Expected: konflate PR check renders the Deployment with the new arg.

---

### Task 3: Live verification (post-merge)

**Files:** none (runtime only)

- [ ] **Step 1: Confirm the rollout** — after Flux pulls the merge and the Deployment restarts (strategy `Recreate`):

```bash
kubectl get hr radar -n radar
kubectl get deploy radar -n radar -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep allowed-hosts
```
Expected: HelmRelease Ready/Healthy; the arg shows `radar.oxygn.dev` among the allowed hosts (comma-joined with the Service name and the chart-default entry).

- [ ] **Step 2: Browser + MCP smoke** — open `https://radar.oxygn.dev` (expected: UI loads, no refusal error; login prompt absent since `auth.mode: none`), then exercise a radar MCP tool from the litellm `radar` alias and confirm radar logs show a successful MCP request.

- [ ] **Step 3: Record outcomes** in the PR (both checks green) and link the archived OIDC plan commit for the future authentication follow-up.

---

## Self-review performed (by plan author)

- **Spec coverage:** matches the user's one-line pivot (no auth now); root-cause fix via the chart's documented value; deferred OIDC is preserved, not lost.
- **Placeholder scan:** all values/args/commands are concrete; `"*"` explicitly forbidden.
- **Type/name consistency:** `--allowed-hosts` list comes from the chart deployment template (`radar.radar` + our `allowedHosts` entry); file paths match the repo layout on main (`kubernetes/apps/radar/radar/`).
