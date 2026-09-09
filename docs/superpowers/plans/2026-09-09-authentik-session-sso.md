# authentik : sessions persistantes + SSO transparent — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Éliminer les re-login « aléatoires » (session authentik perdue à la fermeture du navigateur) et rendre la navigation inter-apps totalement transparente (implicit consent).

**Architecture:** Un nouveau blueprint authentik (ConfigMap monté par le Helm chart, pattern existant des blueprints `mainclaw`/`opencode`) patche le `UserLoginStage` par défaut (`session_duration: days=7`, `remember_me_offset: days=30`). Les providers OIDC `mainclaw` et `opencode` passent du flow de consentement explicite au flow implicite. Spéc : `docs/superpowers/specs/2026-09-09-authentik-session-sso-design.md`.

**Tech Stack:** Flux (Kustomization + HelmRelease), authentik 2026.8.1 (chart OCI `ghcr.io/goauthentik/helm-charts/authentik`), blueprints authentik, validation `flate` (via mise).

## Global Constraints

- Ne **jamais** mettre `metadata.namespace` inline sur `HelmRelease` ou `Kustomization` (injecté par kustomize / `spec.targetNamespace`).
- Le ConfigMap blueprint doit vivre dans le namespace `security` (c'est là qu'authentik le monte) — il est dans la même Kustomization qu'authentik, donc c'est automatique.
- Validation locale obligatoire avant push : `mise exec -- flate test ks --path ./kubernetes/apps` (exit 0).
- Workflow branche + PR : jamais committer directement sur `main` pour les manifests.
- Messages de commit en style conventional (`feat:`, `fix:`, `docs:`).
- Durées exactes validées dans le spec : `session_duration: days=7`, `remember_me_offset: days=30`, flow `default-provider-authorization-implicit-consent`.

---

### Task 1: Branche + blueprint session authentik

**Files:**
- Create: `kubernetes/apps/security/authentik/app/blueprint.yaml`
- Modify: `kubernetes/apps/security/authentik/app/kustomization.yaml`
- Modify: `kubernetes/apps/security/authentik/app/helmrelease.yaml:14-16`

**Interfaces:**
- Consumes: stage par défaut authentik identifié `default-authentication-login` (modèle `authentik_stages_user_login.userloginstage`, présent en base via le blueprint par défaut d'authentik).
- Produces: ConfigMap `authentik-blueprint` référencé dans `blueprints.configMaps` du HelmRelease — Task 2 dépend du fait que ce mécanisme fonctionne (reloader redémarre authentik quand le ConfigMap change).

- [ ] **Step 1: Créer la branche**

```bash
git checkout -b feat/authentik-session-sso
```

- [ ] **Step 2: Créer le fichier blueprint**

Créer `kubernetes/apps/security/authentik/app/blueprint.yaml` avec exactement ce contenu :

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: authentik-blueprint
data:
  authentik.yaml: |
    version: 1
    metadata:
      name: Authentik Session
    entries:
      - identifiers:
          name: default-authentication-login
        model: authentik_stages_user_login.userloginstage
        attrs:
          session_duration: days=7
          remember_me_offset: days=30
```

- [ ] **Step 3: Ajouter le ConfigMap à la kustomization**

Dans `kubernetes/apps/security/authentik/app/kustomization.yaml`, remplacer :

```yaml
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  - ./externalsecret.yaml
```

par :

```yaml
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  - ./blueprint.yaml
  - ./externalsecret.yaml
```

- [ ] **Step 4: Référencer le blueprint dans le HelmRelease**

Dans `kubernetes/apps/security/authentik/app/helmrelease.yaml`, remplacer :

```yaml
    blueprints:
      configMaps:
        - mainclaw-blueprint
        - opencode-blueprint
```

par :

```yaml
    blueprints:
      configMaps:
        - authentik-blueprint
        - mainclaw-blueprint
        - opencode-blueprint
```

- [ ] **Step 5: Valider l'app avec flate**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/security/authentik/app
```

Expected: succès (exit 0, aucune erreur de schema/référence). Si le ConfigMap manquait dans `blueprints.configMaps`, flate le signalerait — pas le cas ici.

- [ ] **Step 6: Validation globale**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
```

Expected: exit 0, toutes les Kustomizations validées.

- [ ] **Step 7: Commit**

```bash
git add kubernetes/apps/security/authentik/app/blueprint.yaml \
        kubernetes/apps/security/authentik/app/kustomization.yaml \
        kubernetes/apps/security/authentik/app/helmrelease.yaml
git commit -m "feat(authentik): persist sessions for 7d with 30d remember-me option"
```

---

### Task 2: Implicit consent sur les providers OIDC (mainclaw + opencode)

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/blueprint/blueprint-mainclaw.yaml:27`
- Modify: `kubernetes/apps/ai/opencode/blueprint/blueprint-opencode.yaml:27`

**Interfaces:**
- Consumes: flow par défaut authentik slug `default-provider-authorization-implicit-consent` (existe en base via les blueprints par défaut d'authentik).
- Produces: rien — changement autonome, indépendant du Task 1 (un reviewer peut approuver l'un sans l'autre).

- [ ] **Step 1: mainclaw — remplacer le flow d'autorisation**

Dans `kubernetes/apps/ai/mainclaw/blueprint/blueprint-mainclaw.yaml`, remplacer :

```yaml
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-explicit-consent]]
```

par :

```yaml
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
```

- [ ] **Step 2: opencode — remplacer le flow d'autorisation**

Dans `kubernetes/apps/ai/opencode/blueprint/blueprint-opencode.yaml`, remplacer :

```yaml
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-explicit-consent]]
```

par :

```yaml
          authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
```

- [ ] **Step 3: Validation**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
```

Expected: exit 0. (Les fichiers modifiés sont des ConfigMaps simples dans des Kustomizations existantes — `flate` valide le build kustomize des deux répertoires `ai/*/blueprint`.)

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/blueprint/blueprint-mainclaw.yaml \
        kubernetes/apps/ai/opencode/blueprint/blueprint-opencode.yaml
git commit -m "feat(ai): use implicit consent flow for mainclaw and opencode OIDC providers"
```

---

### Task 3: Diff pré-PR, push, ouverture de la PR

**Files:**
- Aucun fichier modifié — étape de vérification et publication.

**Interfaces:**
- Consumes: les commits des Tasks 1 et 2 sur la branche `feat/authentik-session-sso`.
- Produces: PR ouverte, checks konflate/CI attendus au vert.

- [ ] **Step 1: Créer le worktree de baseline**

```bash
git worktree add --detach /tmp/baseline origin/main
```

- [ ] **Step 2: Diff des Kustomizations et HelmReleases**

```bash
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
```

Expected: les seules différences sont (a) le ConfigMap `authentik-blueprint` dans `security`, (b) la liste `blueprints.configMaps` du HelmRelease authentik, (c) la valeur `authorization_flow` des deux providers `ai`. Aucune autre diff.

- [ ] **Step 3: Nettoyer le worktree**

```bash
git worktree remove /tmp/baseline --force
```

- [ ] **Step 4: Push et PR**

```bash
git push -u origin feat/authentik-session-sso
gh pr create --title "feat(authentik): persistent sessions + transparent SSO" --body "Sessions persistantes (7j, remember-me 30j) via blueprint + implicit consent sur mainclaw/opencode. Spec: docs/superpowers/specs/2026-09-09-authentik-session-sso-design.md"
```

Expected: PR créée ; vérifier que le check konflate et la CI passent.

---

### Task 4: Vérification post-merge (accès cluster requis)

**Files:**
- Aucun fichier modifié — vérification live.

**Interfaces:**
- Consumes: PR mergeée dans `main`.
- Produces: confirmation du spec (critères de la section Validation).

- [ ] **Step 1: Observer la sync Flux et le rollout**

```bash
flux reconcile kustomization authentik -n flux-system
kubectl rollout status deployment/authentik-server -n security --timeout=180s
kubectl rollout status deployment/authentik-worker -n security --timeout=180s
```

Expected: reconciliation `Ready`, pods redémarrés par reloader (le ConfigMap a changé) puis `Successfully rolled out`.

- [ ] **Step 2: Vérifier que le blueprint est appliqué**

```bash
kubectl logs -n security deploy/authentik-worker | grep -i "blueprint" | tail -5
```

Expected: logs indiquant l'application du blueprint `Authentik Session` sans erreur.

- [ ] **Step 3: Vérifications manuelles navigateur (utilisateur)**

1. Se connecter sur `authentik.oxygn.dev` (identifiants + MFA) — la case « Remember me » est visible ; la cocher.
2. Fermer le navigateur, le rouvrir, retourner sur `authentik.oxygn.dev` → toujours authentifié (plus de re-login).
3. Aller sur `mainclaw.oxygn.dev` puis `opencode.oxygn.dev` → aucune page authentik n'intercepte la navigation.

Si une vérification échoue : revérifier les logs worker (Step 2) et l'état du stage dans l'admin authentik (Flows → default-authentication-login → session_duration doit valoir `days=7`).
