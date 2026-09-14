# AI PR Review — Primary model `dsv4f` → `dsv41f`

**Date** : 2026-09-14
**Status** : Approved (en conversation)
**Contexte** : suite de [2026-08-30-ai-pr-review-design.md](2026-08-30-ai-pr-review-design.md) — le workflow `.github/workflows/ai-pr-review.yaml` lit `vars.PRIMARY_MODEL` (ai-pr-review.yaml:103), actuellement `dsv4f`.

## Décision

Passer le modèle **primary** de l'AI PR review de `dsv4f` (deepseek-v4-flash) à `dsv41f` (deepseek-v4.1-flash), actuellement moins cher, à qualité de review comparable.

**Changement** : une seule commande runtime GitHub — **aucun fichier du repo modifié** :

```bash
gh variable set PRIMARY_MODEL --body "dsv41f"
```

Effet immédiat à la prochaine review (le workflow lit la variable à chaque run).

## Vérifications

- `dsv41f` déployé dans LiteLLM (`kubernetes/apps/ai/litellm/app/models/dsv41f.yaml`, CR présent) et testé : répond correctement avec `response_format: json_object` (mode requis par l'action `misospace/pr-reviewer-action`).
- `ai_max_tokens: "16000"` ≤ limite output `dsv41f` (16384) — inchangé.
- Smart route (`go-glm-5.3-flash`) et fallback (`MiniMax-M3`) inchangés ; le fallback de l'action couvre déjà les pannes du primary (3 retries + `on_model_failure: notice`), donc pas de fallback routeur LiteLLM ajouté pour `dsv41f` (option rejetée : redondant).

## Rollback

```bash
gh variable set PRIMARY_MODEL --body "dsv4f"
```

## Validation

1. `workflow_dispatch` sur une PR existante → vérifier dans les logs du run que le modèle appelé est `dsv41f`.
2. À la prochaine PR Renovate : la review apparaît normalement (section konflate rendered diff sur un bump de chart).
