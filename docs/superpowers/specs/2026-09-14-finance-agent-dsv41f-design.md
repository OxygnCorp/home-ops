# Agent Finance — primary `dsv41f`, fallback `MiniMax-M3`

**Date** : 2026-09-14
**Status** : Approved (en conversation)
**Contexte** : l'agent `finance` de mainclaw (`kubernetes/apps/ai/mainclaw/app/resources/openclaw.json`, `agents.entries.finance`) n'a pas de clé `model` propre et hérite des defaults : primary `litellm/MiniMax-M3`, fallbacks `go-minimax-m3` → `dsv4f`. Suite au switch d'`ai-pr-review` sur `dsv41f` ([2026-09-14-ai-pr-review-primary-dsv41f-design.md](2026-09-14-ai-pr-review-primary-dsv41f-design.md)), l'agent finance bascule à son tour sur `dsv41f` (deepseek-v4.1-flash) en primary.

## Décision

Override `model` **uniquement pour l'agent finance** :

```json
"model": {
  "primary": "litellm/dsv41f",
  "fallbacks": [
    "litellm/MiniMax-M3",
    "litellm/go-minimax-m3",
    "litellm/dsv4f"
  ]
}
```

- **Primary** : `litellm/dsv41f` (deepseek-v4.1-flash, route OpenCode Zen).
- **Fallbacks** : `MiniMax-M3` (route directe, ex-primary des defaults) puis la chaîne existante (`go-minimax-m3`, `dsv4f`) — décision utilisateur de conserver la chaîne complète.

## Changements

1. `agents.entries.finance.model` — bloc ci-dessus, inséré après `agentDir`.
2. `agents.defaults.modelPolicy.allow` — ajout de `litellm/dsv41f` (absent de l'allowlist, l'agent n'aurait pas pu le sélectionner).

## Hors scope

- Les autres agents continuent d'hériter des defaults (inchangés).
- Catalogue provider/alias : rien à faire, `litellm/dsv41f` existe déjà dans `agents.defaults.models` (alias `dsv41f`) et dans le catalogue du provider litellm (`kubernetes/apps/ai/litellm/app/models/dsv41f.yaml`).

## Rollback

Supprimer le bloc `model` de l'entrée `finance` (retour à l'héritage des defaults) et retirer `litellm/dsv41f` de l'allowlist.

## Validation

1. `jq` : JSON valide, bloc `finance.model` et allowlist présents.
2. `flate test ks --path ./kubernetes/apps` avant push.
3. Post-merge : heartbeat finance (6h) et conversations sur `#finance` — vérifier dans les logs mainclaw que le modèle appelé est `dsv41f`.
