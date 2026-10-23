# Chantier 1 — Élargissement automerge Renovate — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Réduire les merges manuels (~78% aujourd'hui) en élargissant l'automerge Renovate aux minor/patch/digest docker+helm (release-age 3j, exclusions core), en accélérant la cadence à 30 min et en court-circuitant l'AI PR review sur les PR automergées.

**Architecture:** Changements déclaratifs uniquement — config Renovate (JSON5), un champ `schedule` dans un CR `RenovateJob` (Flux-managed), et une condition `if` plus large dans un workflow GitHub Actions. Aucun code runtime.

**Tech Stack:** Renovate (config JSON5 via preset remote `.renovate/*`), renovate-operator (CR `RenovateJob`), GitHub Actions (expression `${{ }}`), Flux.

**Spec:** `docs/superpowers/specs/2026-10-23-renovate-automerge-chantier1-design.md` (même branche)

**Worktree de travail:** `../home-ops-renovate-automerge`, branche `feature/renovate-automerge-chantier1`.

## Global Constraints

- `automergeType: "pr"` partout — jamais de merge de branche (revert one-click exigé par la spec).
- Aucun automerge sur `matchUpdateTypes: ["major"]`.
- Exclusions core : listées verbatim dans la Task 2 (dock. pattern RegEx `matchPackagePatterns`).
- `minimumReleaseAge: "3 days"` sur la nouvelle règle large uniquement ; les règles "trusted" existantes (home-operations, kube-prometheus-stack, renovate, GH actions) restent **inchangées**.
- Pas de `metadata.namespace` inline sur HelmRelease/Kustomization (convention repo).
- Les images conteneurs changées restent épinglées `@sha256:` (l'automerge ne change pas le pinning existant).

## Review Focus

- Ordre des rules dans `autoMerge.json5` : les dernières l'emportent — si la règle d'exclusion core n'est pas après la règle large, les composants core se font automerger. Pin par test : Task 2, Step de vérification d'ordre.
- Workflow AI review : si la condition `if` oublie `workflow_dispatch`, la re-review manuelle casse. Pin : Task 4.
- Cron mal formé → le schedule ne se déclenche jamais (silencieux). Pin : Task 3 (flate + observation du log operator `executing schedule`).
- Label `automerge` oublié dans `addLabels` → le filtre du workflow ne matchera jamais (silencieux). Pin : Task 1/2 réflexion croisée.
- Le preset remote `.renovate/autoMerge.json5` est consommé par Renovate via `github>OxygnCorp/home-ops//.renovate/autoMerge.json5` — une erreur de syntaxe JSON5 casse **tous** les presets du repo au prochain run. Pin : Task 5 (validation).

---

### Task 1: `.renovaterc.json5` — retirer le preset `:automergeBranch`

**Files:**
- Modify: `.renovaterc.json5` (ligne 17, liste `extends`)

**Interfaces:**
- Consumes: —
- Produces: l'absence d'`automergeType: "branch"` implicite ; toutes les règles d'automerge devront porter explicitement `automergeType: "pr"` (garanti par Tasks 2).

- [ ] **Step 1: Éditer le tableau `extends`**

Retirer la ligne `":automergeBranch",` (ligne 17). Ne rien toucher d'autre.

- [ ] **Step 2: Vérifier la syntaxe JSON5 + absence du preset**

Run: `python3 -c "import json5; json5.load(open('.renovaterc.json5'))"` (via `mise exec -- python` ou `python3 -c ...` dans le worktree) — Expected: aucune erreur.
Run: `grep -c automergeBranch .renovaterc.json5` — Expected: `0`.

- [ ] **Step 3: Commit**

```bash
git add .renovaterc.json5
git commit -m "chore(renovate): drop global :automergeBranch preset (PR-only automerge)"
```

### Task 2: `.renovate/autoMerge.json5` — règle large + exclusions core + no-major

**Files:**
- Modify: `.renovate/autoMerge.json5` (réécriture du tableau `packageRules`)

**Interfaces:**
- Consumes: Task 1 (plus d'automergeBranch global).
- Produces: la règle large porte `addLabels: ["automerge"]`, consommé par le filtre du workflow en Task 4.

- [ ] **Step 1: Réécrire le fichier**

Ordre final des rules — tel que dans la spec §2 (verbatim, y compris les pattern RegEx) :

1. Les 4-5 règles **actuelles** `matchDatasources: docker` / `matchManagers: github-actions` (home-operations digests+patches, kube-prometheus-stack minor/patch, renovate image, GH actions trusted/other) — conserver à l'identique (contenu actuel du fichier, lignes 3-52).
2. Nouvelle règle large :
```json5
{
  description: "Auto-merge minor/patch/digest container & chart updates (3-day release age)",
  matchDatasources: ["docker"],
  matchUpdateTypes: ["minor", "patch", "digest"],
  automerge: true,
  automergeType: "pr",
  minimumReleaseAge: "3 days",
  ignoreTests: false,
  addLabels: ["automerge"],
}
```
3. Nouvelle règle d'exclusion core (tous les `matchPackagePatterns` de la spec §2.c, block c, verbatim — coredns/envoy/gateway-api/cilium ; 1password/external-secrets/cert-manager/kanidm ; cloudnative-pg/openebs/miroir/kopiur/tuppr/rook-ceph ; litellm/toolhive/memini/mcp-grafana/unifi-network-mcp/konflate ; gha-runner-scale-set/flux-operator/flux-instance ; kube-apiserver/kube-controller-manager/kube-proxy/kube-scheduler/kubelet ; factory.talos.dev ; siderolabs/installer) avec `automerge: false`.
4. Règle no-major :
```json5
{
  description: "Never auto-merge major updates",
  matchUpdateTypes: ["major"],
  automerge: false,
}
```

- [ ] **Step 2: Vérifier l'ordre et la syntaxe**

Order-check manuel + script : la règle exclusion core doit posséder l'indice **le plus élevé avant la règle no-major** — grep: positions de `"Exclude core/sensitive"` et `"Never auto-merge"` et `"trusted minor"` dans le fichier : exclusion core doit être la dernière des trois.
Run: `python3 -c "import json5; json5.load(open('.renovate/autoMerge.json5'))"` — Expected: aucune erreur.

- [ ] **Step 3: Commit**

```bash
git add .renovate/autoMerge.json5
git commit -m "feat(renovate): broaden automerge to minor/patch/digest with core exclusions"
```

### Task 3: Cadence Renovate — schedule 30 min

**Files:**
- Modify: `kubernetes/apps/renovate/renovate-operator/jobs/github.yaml` (champ `schedule`, sous `apiVersion: renovate-operator.mogenius.com/v1alpha1`, `kind: RenovateJob`)

**Interfaces:**
- Consumes: —
- Produces: exécution des automerges au plus ~30 min après création de la PR (au lieu d'1h).

- [ ] **Step 1: Éditer le schedule**

`schedule: 0 * * * *` → `schedule: */30 * * * *`. Uniquement dans le CR `RenovateJob oxygncorp`.

- [ ] **Step 2: Valider le YAML**

Run: `mise exec -- flate test ks --path ./kubernetes/apps/renovate`
Expected: PASS (toutes les Kustomizations de l'app renovate).

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/renovate/renovate-operator/jobs/github.yaml
git commit -m "feat(renovate): run Renovate every 30 minutes (automerge latency)"
```

### Task 4: Skip AI PR Review sur label `automerge`

**Files:**
- Modify: `.github/workflows/ai-pr-review.yaml` (job `review-pr`, champ `if`, ligne ~34)

**Interfaces:**
- Consumes: Task 2 — le label `automerge` est ajouté par Renovate à la phase de création de PR.
- Produces: —

- [ ] **Step 1: Éditer la condition `if` du job `review-pr`**

Remplacer :

```yaml
if: ${{ (github.event_name == 'pull_request' && !github.event.pull_request.draft) || github.event_name == 'workflow_dispatch' }}
```

par :

```yaml
if: ${{ (github.event_name == 'pull_request' && !github.event.pull_request.draft && !contains(github.event.pull_request.labels.*.name, 'automerge')) || github.event_name == 'workflow_dispatch' }}
```

- [ ] **Step 2: Valider le YAML du workflow**

Run: `yamllint .github/workflows/ai-pr-review.yaml` (pyYAML dispo via `mise exec -- python`) ou simplement `python3 -c "import yaml, sys; yaml.safe_load(open('.github/workflows/ai-pr-review.yaml'))"`.
Expected: aucune erreur.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ai-pr-review.yaml
git commit -m "ci(ai-pr-review): skip review for automerge-labeled PRs"
```

### Task 5: Validation globale + push + PR

**Files:**
- Create: — (aucun fichier)

- [ ] **Step 1: Valider tout le repo des tests**

Run: `mise exec -- flate test ks --path ./kubernetes/apps`
Expected: PASS.

- [ ] **Step 2: Diff vs baseline main**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: uniquement le changement de `schedule` sur le RenovateJob.

- [ ] **Step 3: Push + PR**

```bash
git push -u origin feature/renovate-automerge-chantier1
gh pr create --title "chore(renovate): broadened automerge with core exclusions" --body-file - <<'EOF'
## Chantier 1 — élargissement automerge Renovate
 Implements the spec docs/superpowers/specs/2026-10-23-renovate-automerge-chantier1-design.md

- drop global :automergeBranch preset → PR-only automerge (revert one-click)
- new broad rule minor/patch/digest, release-age 3 days, label `automerge`
- core exclusions (coredns, envoy, secrets identity, storage/DB, AI chain, k8s/talos/flux core)
- never automerge majors
- RenovateJob schedule hourly → 30 min
- AI PR Review skipped for `automerge`-labeled PRs
EOF
```

- [ ] **Step 4: Vigilance sur le merge**

MERGE SEULEMENT avec le verdict de l'utilisateur (cette PR n'a PAS de label `automerge`, donc elle sera reviewée par le workflow AI PR Review normal).

Aucune action cluster manuelle requise : Flux appliquera le RenovateJob modifié et Renovate exécutera au prochain tick.

## Post-merge monitoring (laissé à l'utilisateur)

- Fenêtre d'observation 5-7 jours : comparer `mergedBy` (`oxygn-admin` vs `mushu-bot[bot]`).
- Cible : ratio auto/humain ≥ 2:1 (vs ~1:2.5 aujourd'hui).
- 0 incident sur un composant core. Si un incident survient sur une PR automergée : revert one-click de la PR, puis réévaluer la liste d'exclusions.

## Notes

- Renovate ne réétiquette pas rétroactivement les PRs ouvertes avant le merge ; les labels `automerge` n'apparaissent que sur les PRs créées après.
- Force une re-review AI : `gh workflow_run` via `gh pr edit --remove-label` ou `workflow_dispatch` avec `pr_number`.
