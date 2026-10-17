# Kanidm OIDC Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Authentik with Kanidm (eleboucher's pattern) as the cluster SSO for
mainclaw, opencode and hermes.

**Architecture:** Two sequential PRs. PR1 is purely additive: an idle Kanidm (app-template
StatefulSet + `ghcr.io/m00nwtchr/kanidm-provision` watcher controller) plus a NEW component
`kubernetes/components/oidc-kanidm/` (base + envoy) that no consumer includes yet, so
Authentik keeps serving everything unchanged. PR2 (after the human bootstraps Kanidm) switches
the three consumers to the new component, removes the old `kubernetes/components/oidc/` and
removes Authentik entirely. (Ruling in the ledger: the consumers already include
`components/oidc/envoy`, so rewriting that path in PR1 would break their OIDC at merge time.)

**Tech Stack:** Flux (HelmRelease app-template), Kanidm 1.11.2, kanidm-provision, cert-manager,
Envoy Gateway `SecurityPolicy`, external-secrets, kopiur.

**Spec:** the plan itself (pattern reference: eleboucher/homelab
git.erwanleboucher.dev — `apps/security/kanidm`, `components/oidc/{base,envoy}`).

## Global Constraints

- Repo: OxygnCorp/home-ops, worktree `/home/nea0d/git/home-ops-kanidm`, branch `feat/kanidm-oidc`.
- Public domain `oxygn.dev`; idiom `authentik.oxygn.dev` → `idm.oxygn.dev`.
- Keep user naming: SecurityPolicy `${APP}-oidc`, param `OIDC_ROUTE_NAME` (mainclaw route is
  `mainclaw-main`). Client secret keys stay `client-id`/`client-secret`.
- Authentik must stay functional through PR1 (existing OAuth2 providers live in its DB;
  blueprints only maintain them — removing blueprint ConfigMaps wiring is safe provided the
  authentik HelmRelease no longer mounts them).
- PR1 and PR2 are separate branches/PRs; PR2 opens only after PR1 merges AND the human
  bootstrap is done (Kanidm admin recovery + provision token in 1Password).
- Verify each task: `mise exec -- flate test ks --path ./kubernetes/apps`,
  `mise exec -- flate test hr --path ./kubernetes/apps` (scoped per task where stated), and
  `flate diff` vs origin/main before PR; konflate renders the PR diff as a status check.
- Never stage files outside this plan's own changes.

## Review Focus

- The nested Flux Kustomization `kanidm-${APP}-oidc` produced by the component must resolve in
  a real kustomize build of each consumer KS (names, separators, dependsOn).
- The authentik HelmRelease must not reference pruned blueprint ConfigMaps in PR1 (chart mounts
  configMaps; a missing mount key breaks the worker pod).
- The provision controller RBAC must match what it needs (read ConfigMaps with
  `kanidm_config: "1"` cluster-wide, create/patch Secrets).
- SecurityPolicy `clientSecretRef` must point at the secret the provisioner will actually write
  (`kanidm-${APP}-oidc`) in the app namespace after PR2, and at the ES-provided
  `${APP}-oidc` secret before it (never both).
- Hermes helrelease env var shapes must keep working (envFromRef secret `hermes` replaced by
  direct valueFrom inserts).

---

### Task 1: Kanidm app under kubernetes/apps/security/kanidm

**Files:**
- Create: `kubernetes/apps/security/kanidm/ks.yaml`
- Create: `kubernetes/apps/security/kanidm/app/kustomization.yaml`, `ocirepository.yaml`,
  `helmrelease.yaml`, `certificate.yaml`, `backendtlspolicy.yaml`, `externalsecret.yaml`,
  `networkpolicy.yaml` (only if repo pattern uses one), `README.md`

**Interfaces:**
- Produces: HelmRelease `kanidm` (security), SA-bound RBAC (read ConfigMaps, create/patch
  Secrets), service `kanidm` (8443 TLS, 3636 LDAP), Secret `kanidm-provision-token`
  (ExternalSecret ← 1Password item `kanidm-provision`), route `idm.oxygn.dev` → envoy-external.
  The oidc/base component dependsOn `kanidm` (security).

- [ ] **Step 1: Read repo conventions** — existing app dirs (podinfo-grade app-template usage,
      chart pin style, networkpolicy patterns) to copy exactly.
- [ ] **Step 2: Write the app files** — StatefulSet `kanidm` (server 1.11.2, TLS from
      cert-manager secret, db PVC, probes /status HTTPS) + controller `provision`
      (kanidm-provision digest-pinned) + RBAC in the HelmRelease + gatus annotation on route
      (repo style) as decided in Task R1.1 rulings.
- [ ] **Step 3: Verify** — `mise exec -- flate test hr --path ./kubernetes/apps/security/kanidm`
      AND `mise exec -- flate test ks --path ./kubernetes/apps/security` both pass.
- [ ] **Step 4: Commit.**

### Task 2: Rewrite components/oidc to kanidm base + envoy

**Files:**
- Create: `kubernetes/components/oidc/base/{kustomization,ks}.yaml`,
  `kubernetes/components/oidc/base/kanidm/{kustomization,configmap}.yaml`
- Create: `kubernetes/components/oidc/envoy/kustomization.yaml` (Component: ../base +
  ./securitypolicy.yaml), `securitypolicy.yaml`
- Modify: `kubernetes/components/oidc/README.md`
- Create: `kubernetes/components/oidc/base/README.md`? (only if README says so)
- Reference: `docs/superpowers/plans/2026-10-17-kanidm-oidc.md` (this plan)

**Interfaces:**
- Produces: Flux Kustomization `kanidm-${APP}-oidc` (ns security, dependsOn kanidm, path
  ./kubernetes/components/oidc/base/kanidm) + ConfigMap `kanidm-${APP}-oidc` labeled
  `kanidm_config: "1"` (state.json kanidm-provision schema; extra.json k8s client keys;
  targetNamespace substitute); SecurityPolicy `${APP}-oidc` (issuer
  `https://idm.oxygn.dev/oauth2/openid/${APP}`, explicit authorizationEndpoint
  `https://idm.oxygn.dev/ui/oauth2` and tokenEndpoint `https://idm.oxygn.dev/oauth2/token`,
  clientID `${APP}`, clientSecret Secret `kanidm-${APP}-oidc`, redirectURL
  `https://${SUBDOMAIN}.oxygn.dev${OIDC_CALLBACK}`, logoutPath `/logout`,
  targetRef HTTPRoute `${OIDC_ROUTE_NAME}`).
- Consumes: Task R1.1 HelmRelease `kanidm` (dependsOn).

- [ ] **Step 1: Write base/ + envoy/ + README, with substitutes documented (APP,
      APP_NAMESPACE, SUBDOMAIN, DOMAIN, OIDC_CALLBACK, OIDC_DISPLAY_NAME,
      OIDC_EXTRA_CALLBACKS, scopes default [openid,profile,email,groups], group users).**
- [ ] **Step 2: kustomize-build proof of the component** against a scratch consumer that sets
      all variables: `mise exec -- kustomize build <scratch> --load-restrictor=...` renders
      both Kustomization + SecurityPolicy ( Comparative vs consumer namespaces).
- [ ] **Step 3: Verify** — `flate test ks --path ./kubernetes/apps` still passes (component
      not yet consumed — nothing breaks).
- [ ] **Step 4: Commit.**

### Task 3: Root-kustomization entry for kanidm

**Files:**
- Modify: `kubernetes/apps/security/kustomization.yaml` — add kanidm entry (authentik stays)

**Interfaces:**
- Consumes: R1.1 kanidm ks.yaml exists.

- [ ] **Step 1: Flate test** scoped to security: both `flate test ks` +
      `flate test hr` clean.
- [ ] **Step 2: Commit.**

### Task 4: Full local validation + rendered-diff sanity + PR1

- [ ] **Step 1: flate test ks + hr** on ./kubernetes/apps — full pass.
- [ ] **Step 2: flate diff vs origin/main** (ks + hr) — only expected additions (kanidm app +
      new oidc-kanidm component); authentik untouched (PR1 is additive).
- [ ] **Step 3: Push branch, open PR1** `feat(security): deploy kanidm with provision and
      kanidm-based oidc component`, wait for CI + konflate + ai-review, address findings.
- [ ] **Step 4: Report merge readiness to the human; PAUSE here** (bootstrap gate).

### Task R2.x (after PR1 merge + human bootstrap): consumer flip + authentik removal

**Files (branch `refactor/kanidm-oidc-consumers`, rebased on merged main):**
- Modify: `kubernetes/apps/ai/mainclaw/ks.yaml` (components oidc→oidc-kanidm/envoy; add
  APP_NAMESPACE/OIDC_DISPLAY_NAME/OIDC_CALLBACK; dependsOn authentik→kanidm)
- Modify: `kubernetes/apps/ai/opencode/ks.yaml` (same; keep routes external), delete the
  `opencode-oidc` ExternalSecret block in `app/externalsecret.yaml`
- Modify: `kubernetes/apps/ai/hermes/ks.yaml` (add components/oidc-kanidm base; substitutes),
  `app/helmrelease.yaml` (HERMES_DASHBOARD_OIDC_ISSUER literal URL + client id/secret via
  secret `kanidm-hermes-oidc`), delete OIDC entries in `app/externalsecret.yaml`
- Modify: `mainclaw/app/externalsecret.yaml` (delete mainclaw-oidc ES block)
- Modify: `kubernetes/apps/ai/opencode/README.md`
- Modify: `kubernetes/apps/security/authentik/ks.yaml` (drop 3 blueprint dependsOn) and
  `app/helmrelease.yaml` (keep only `authentik-blueprint` in `blueprints.configMaps`) — only
  if authentik must keep running during the PR2 window; default target is full removal in the
  same revision, making those steps moot
- Delete: `kubernetes/apps/security/authentik/`, `kubernetes/components/oidc/`
  (old component), the three `ks-blueprint.yaml` files + their `kubernetes/apps/ai`
  kustomization entries
- Modify: `kubernetes/apps/security/kustomization.yaml` (remove authentik entry)

- [ ] **Step 1: All flate tests green; flate diff shows exactly the consumer re-pointing +
      authentik removal.**
- [ ] **Step 2: Push + PR2; verify konflate rendered diff; AI review.**
- [ ] **Step 3: Post-merge cluster checks** (flux ks status, SecurityPolicy translation,
      login flows for the three apps, 1Password cleanup list for the human).

## Post-merge manual steps (human, per README)

1. Recover kanidm admin/idm_admin accounts; set real passwords.
2. Create `kanidm-provision` service-account + API token → store 1Password item
   `kanidm-provision`.
3. Groups `users`/`admins` + personal account + passkey.
4. PR2 merge; test login flows.
5. 1Password cleanup (item `authentik`, client-id/secret fields of `opencode`, `mainclaw`,
   `hermes`, item postgres authentik).
