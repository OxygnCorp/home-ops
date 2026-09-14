# memini — LLM model `dsv41f` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Passer `MEMINI_LLM_MODEL` de `dsv4f` à `dsv41f` (moins cher) dans le HelmRelease memini, via PR.

**Architecture:** Une ligne dans `kubernetes/apps/ai/memini/app/helmrelease.yaml:37` ; Flux reconcile le HelmRelease après merge et redémarre memini avec le nouvel env. Modèle `dsv41f` déjà déployé dans LiteLLM (CR `dsv41f`, validé json_object, max output 16384). Spec : [2026-09-14-memini-llm-dsv41f-design.md](../specs/2026-09-14-memini-llm-dsv41f-design.md).

**Tech Stack:** kustomize/HelmRelease (Flux), `flate` (validation locale), `gh` (PR).

## Global Constraints

- Une seule ligne modifiée : `MEMINI_LLM_MODEL: dsv41f` — ne rien toucher d'autre.
- Pas de fallback routeur LiteLLM à ajouter (décision héritée du spec PR review).
- Rollback : revert du commit (1 ligne).

---

### Task 1: Éditer le HelmRelease et valider localement

**Files:**
- Modify: `kubernetes/apps/ai/memini/app/helmrelease.yaml:37`
- Test: `flate test hr` sur le répertoire memini

**Interfaces:**
- Produces: commit unique sur `chore/memini-llm-dsv41f` modifiant `MEMINI_LLM_MODEL`, validé par flate.

- [ ] **Step 1: Modifier la ligne 37**

Dans `kubernetes/apps/ai/memini/app/helmrelease.yaml`, remplacer :

```yaml
              MEMINI_LLM_MODEL: dsv4f
```

par :

```yaml
              MEMINI_LLM_MODEL: dsv41f
```

- [ ] **Step 2: Vérifier le diff**

Run: `git diff`
Expected: exactement 1 hunk, 1 ligne (`-MEMINI_LLM_MODEL: dsv4f` / `+MEMINI_LLM_MODEL: dsv41f`).

- [ ] **Step 3: Valider avec flate**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/memini`
Expected: succès (HelmRelease memini rendu sans erreur schéma/références).

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/ai/memini/app/helmrelease.yaml
git commit -m "feat(memini): switch llm model dsv4f -> dsv41f"
```

### Task 2: Pousser et créer la PR

**Files:**
- Aucun (git + gh).

**Interfaces:**
- Consumes: commit du Task 1 sur `chore/memini-llm-dsv41f`.
- Produces: PR ouverte, checks CI (image-pull) + konflate (rendered diff) sur la PR.

- [ ] **Step 1: Push et création de la PR**

```bash
git push -u origin chore/memini-llm-dsv41f
gh pr create --fill --body "Spec: docs/superpowers/specs/2026-09-14-memini-llm-dsv41f-design.md — même décision que le PR review (dsv41f moins cher)."
```

Expected: URL de PR retournée.

- [ ] **Step 2: Vérifier les checks**

Run: `gh pr checks --watch`
Expected: tous les checks passent (CI image-pull, konflate status). Le commentaire konflate doit montrer le diff rendu : env `MEMINI_LLM_MODEL: dsv41f`.

- [ ] **Step 3: Merge (après revue konflate + validation humaine)**

Laisser l'utilisateur reviewer/merger via l'UI, ou sur approbation explicite :

```bash
gh pr merge --merge
```

### Task 3: Validation post-merge

**Files:**
- Aucun (inspection cluster).

**Interfaces:**
- Consumes: PR mergée → Flux reconcile.

- [ ] **Step 1: Forcer la reconcile et attendre**

```bash
flux reconcile helmrelease memini -n ai
```

Expected: HelmRelease `memini` → Ready.

- [ ] **Step 2: Vérifier l'env du pod**

```bash
kubectl get pods -n ai -l app.kubernetes.io/instance=memini
kubectl exec -n ai deploy/memini -- printenv MEMINI_LLM_MODEL
```

Expected: pod en `Running` (startup probe OK) et `MEMINI_LLM_MODEL=dsv41f`.

- [ ] **Step 3: Vérifier les logs LLM**

```bash
kubectl logs -n ai deploy/memini --since=10m | grep -iE "error|llm" | tail -20
```

Expected: pas d'erreur LLM après le restart (les appels extraction/synthèse passent via `dsv41f`).
