# AI PR Review — Primary model `dsv41f` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Basculer le modèle primary de l'AI PR review de `dsv4f` à `dsv41f` (moins cher), via la variable GitHub `PRIMARY_MODEL` — zéro changement de fichier.

**Architecture:** Le workflow `.github/workflows/ai-pr-review.yaml:103` lit `vars.PRIMARY_MODEL` à chaque run ; le changement est purement runtime (`gh variable set`), effectif immédiatement, rollback par la même commande. Spec : [2026-09-14-ai-pr-review-primary-dsv41f-design.md](../specs/2026-09-14-ai-pr-review-primary-dsv41f-design.md).

**Tech Stack:** GitHub CLI (`gh`), GitHub Actions (`workflow_dispatch`), LiteLLM (déjà déployé, modèle `dsv41f` vérifié).

## Global Constraints

- Aucun fichier du repo modifié pour le switch lui-même (variable GitHub runtime uniquement).
- `ai_max_tokens: "16000"` ≤ limite output `dsv41f` (16384) — déjà le cas, ne pas toucher au workflow.
- Smart (`go-glm-5.3-flash`) et fallback (`MiniMax-M3`) inchangés.
- Pas de fallback routeur LiteLLM à ajouter pour `dsv41f` (rejeté dans le spec : redondant avec le fallback de l'action).
- Rollback : `gh variable set PRIMARY_MODEL --body "dsv4f"`.

---

### Task 1: Basculer la variable GitHub `PRIMARY_MODEL`

**Files:**
- Aucun (variable GitHub runtime).

**Interfaces:**
- Consumes: variable repo GitHub `PRIMARY_MODEL` (état actuel : `dsv4f`).
- Produces: `PRIMARY_MODEL` = `dsv41f`, consommé par `.github/workflows/ai-pr-review.yaml` (`ai_model: ${{ vars.PRIMARY_MODEL }}`).

- [ ] **Step 1: Vérifier l'état actuel de la variable**

Run: `gh variable get PRIMARY_MODEL`
Expected: `PRIMARY_MODEL	dsv4f`

- [ ] **Step 2: Appliquer le changement**

```bash
gh variable set PRIMARY_MODEL --body "dsv41f"
```

Expected: exit 0, pas de sortie.

- [ ] **Step 3: Vérifier la nouvelle valeur**

Run: `gh variable get PRIMARY_MODEL`
Expected: `PRIMARY_MODEL	dsv41f`

### Task 2: Validation — review de bout en bout sur `dsv41f`

**Files:**
- Aucun (déclenchement + lecture des logs d'un run).

**Interfaces:**
- Consumes: `PRIMARY_MODEL` = `dsv41f` (Task 1), workflow `ai-pr-review.yaml` avec input `pr_number`.
- Produces: preuve dans les logs que le modèle appelé est `dsv41f`.

- [ ] **Step 1: Identifier une PR de test**

Run: `gh pr list --state open --limit 1 --json number,title --jq '.[0].number'`
Expected: un numéro de PR ouvert (une PR Renovate convient). Si aucune PR ouverte : attendre la prochaine PR Renovate et sauter le `workflow_dispatch` (la validation passe alors par ce run naturel).

- [ ] **Step 2: Déclencher une re-review manuelle**

```bash
gh workflow run ai-pr-review.yaml -f pr_number=<PR_NUMBER>
```

Expected: exit 0.

- [ ] **Step 3: Suivre le run et vérifier le modèle appelé**

```bash
sleep 10
RUN_ID=$(gh run list --workflow=ai-pr-review.yaml --event=workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID" --exit-status || true
gh run view "$RUN_ID" --log | grep -i "dsv41f"
```

Expected: le run se termine (success ou notice advisory si échec modèle) et les logs mentionnent `dsv41f` comme modèle primary. Le grep doit retourner au moins une ligne.

- [ ] **Step 4: Vérifier la review publiée**

Run: `gh pr view <PR_NUMBER> --json reviews --jq '.reviews[-1].body' | head -20`
Expected: une review AI récente est présente (ou le commentaire "review impossible" si dégradation — dans ce cas investiguer via rollback et logs LiteLLM).

## Rollback (si Task 2 échoue modèle)

```bash
gh variable set PRIMARY_MODEL --body "dsv4f"
gh variable get PRIMARY_MODEL   # Expected: PRIMARY_MODEL	dsv4f
```
