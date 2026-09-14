# memini — LLM model `dsv4f` → `dsv41f`

**Date** : 2026-09-14
**Status** : Approved (en conversation)
**Contexte** : même décision que [2026-09-14-ai-pr-review-primary-dsv41f-design.md](2026-09-14-ai-pr-review-primary-dsv41f-design.md) (`dsv41f` moins cher que `dsv4f`, déjà déployé et testé dans LiteLLM) — appliquée cette fois au consommateur **memini**, via GitOps.

## Décision

`kubernetes/apps/ai/memini/app/helmrelease.yaml:37` :

```yaml
MEMINI_LLM_MODEL: dsv41f
```

Unique référence à `dsv4f` dans l'arbre `kubernetes/apps/ai/memini/` (vérifié). Aucun autre changement : `MEMINI_LLM_BASE_URL` pointe déjà sur `http://litellm.ai:4000/v1`.

## Décisions héritées

- Pas de fallback routeur LiteLLM pour `dsv41f` (rejeté dans le spec PR review : redondant ; memini n'a de toute façon pas de fallback applicatif aujourd'hui).
- `dsv41f` validé : json_object OK, max output 16384. memini utilise le modèle pour l'extraction/synthèse de mémoire (pas de contrainte vision).

## Flow

Worktree `chore/memini-llm-dsv41f` (base `origin/main`) → commit → `flate test hr memini` → push → **PR** (review konflate + CI) → merge.

## Validation

1. `flate test hr --path ./kubernetes/apps/ai/memini` avant push.
2. Post-merge : Flux reconcile → HelmRelease Ready → pod `memini` redémarré avec le nouvel env → probe startup `/healthz` OK.
3. Logs memini : appels LLM sans erreur après le restart.

## Rollback

Revert du commit (1 ligne).
