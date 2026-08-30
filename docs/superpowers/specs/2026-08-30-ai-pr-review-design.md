# AI PR Review — Design

**Date**: 2026-08-30
**Status**: Approved (en conversation)
**Source**: portage de [joryirving/home-ops `ai-pr-review.yaml`](https://github.com/joryirving/home-ops/blob/3d30152f24455de010aedf6d0653da0339a287a4/.github/workflows/ai-pr-review.yaml) (commit 3d30152)
**Dépend de**: konflate déployé (PR #4099) + MCP public (`mcp: true`), LiteLLM (`litellm.oxygn.dev`), SearXNG (`search.oxygn.dev`), runner ARC `home-ops-runner`

## Contexte

Reviews de PRs par un modèle AI, basées sur l'action réutilisable
`misospace/pr-reviewer-action` (v2.2.1, pin SHA). L'action :

1. **Precheck** : fingerprint du diff — skip si inchangé depuis la dernière review.
2. **Attente CI** (`ci_status_check: true`) : les résultats des checks sont injectés dans le corpus.
3. **Collecte du contexte** : diff, fichiers, issues liées, sources amont (allowlist), evidence providers (scripts repo), tool harness (`gh_api`, `web_search`/`web_fetch` via SearXNG, MCP konflate).
4. **Classification déterministe** (règles, pas de modèle) : `renovate_digest_only`, `k8s_manifest`, `auth_changes`, etc. + `must_check` par classe de risque.
5. **Routage** : primary (PRs simples) / smart (escalade auto : risk flags, low-confidence, request_changes) / fallback (si primary en échec).
6. **Validation** : les `must_check` non traités par le modèle sont signalés (mode `warn`).
7. **Publication** : review GitHub native (`review_comment`) + findings inline ancrés aux lignes. Advisory uniquement — ne bloque jamais le merge.

Déclencheurs : `pull_request` (opened, reopened, synchronize, ready_for_review,
labeled) + `workflow_dispatch` (numéro de PR). Le label `ai-review` force une
re-review (auto-supprimé après). PRs draft ignorées. Concurrency par PR avec
`cancel-in-progress` ; les événements `labeled` ont un groupe dédié pour ne pas
s'annuler entre eux.

## Décisions

| Sujet | Décision |
|---|---|
| Backend AI | LiteLLM existant : `https://litellm.oxygn.dev/v1` (route interne `envoy-internal`) |
| Routage modèles | primary = `dsv4f`, smart = `zai-glm-5.2`, fallback = `MiniMax-M3` — tous OpenAI-compat, `ai_api_format: openai`, `ai_response_format: json_object`, `ai_max_tokens: "16000"` |
| Clé API | master key LiteLLM en secret Actions `LITELLM_API_KEY` (virtual key dédiée = évolution possible, pas bloquante) |
| Identité GitHub | réutiliser l'app konflate (client ID `Iv23lizpdaSYJBX0uzo8`) — elle a déjà `contents:read` + `pull-requests:write` (elle poste les commentaires konflate). Même pattern que jory (app bot unique partagée, item 1Password `github-bot`/konflate). |
| Runner | `runs-on: home-ops-runner` (ARC, in-cluster) — seul moyen d'atteindre LiteLLM/SearXNG sur routes internes sans exposition publique |
| Mode publication | `publish_mode: review_comment` + `inline_findings: "true"` — advisory, jamais de gate de merge |
| konflate | MCP public `https://konflate.oxygn.dev/mcp` : evidence provider (injection déterministe du diff rendu) + `tool_mcp_servers` (follow-up à la demande du modèle) |
| SearXNG | `https://search.oxygn.dev/search` pour `web_search` dans le tool loop |
| Evidence providers | les 2 de jory : konflate (diff Flux rendu) + upgrade-impact (release notes amont + drift des values Helm) |

## Fichiers

| Fichier | Contenu / adaptation |
|---|---|
| `.github/workflows/ai-pr-review.yaml` | Portage du workflow de jory : `runs-on: home-ops-runner`, `KONFLATE_MCP_URL: https://konflate.oxygn.dev/mcp`, `search_url: https://search.oxygn.dev/search`, secrets `APP_CLIENT_ID`/`APP_PRIVATE_KEY`/`LITELLM_API_KEY`, vars `LITELLM_URL`/`PRIMARY_MODEL`/`SMART_MODEL`/`FALLBACK_MODEL` (formats tous `openai`, hardcoded). Step setup ajouté : `helm` + `PyYAML` pour le drift chart (absents des runners ARC, préinstallés sur ubuntu-latest). `allowed_source_hosts` adaptés au repo : github.com, api.github.com, gitlab.com, registry.terraform.io, artifacthub.io, talos.dev, www.talos.dev, docs.siderolabs.com (minecraft retiré). |
| `.agents/instructions/pr-review.instructions.md` | System prompt addendum (`system_prompt_mode: append`) : conventions de **notre** AGENTS.md — namespace injecté par kustomize (ne pas flagger), OCI ≠ digests (ne pas exiger `@sha256:` sur les charts), revues compactes pour les digest-only Renovate, outils konflate (`mcp__konflate__get_pr_summary`/`get_pr_diff`), vérification systématique des release notes amont. |
| `.github/konflate-evidence-providers.json` | Identique à jory : déclare les 2 scripts, timeouts 45s/90s |
| `.github/scripts/konflate_evidence.py` | URL défaut → `https://konflate.oxygn.dev/mcp` ; sinon identique (MCP streamable-http, `get_pr_summary` + `get_pr_diff`, sentinelles "no pull request tracked"/"still rendering" → findings vides) |
| `.github/scripts/upgrade_impact_evidence.py` | Identique à jory (parsing des bumps `ocirepository.yaml`/`helmrelease.yaml`, release notes via `gh api`, drift `helm show values` old→new intersecté avec nos values) — compatible avec notre structure `kubernetes/**` |
| `.github/labels.yaml` | + label `ai-review` (re-review one-click) |

## Config GitHub (manuel, post-merge)

Secrets (source 1Password, item konflate / github-bot) :
- `APP_CLIENT_ID` = client ID de l'app konflate
- `APP_PRIVATE_KEY` = private key PEM de l'app
- `LITELLM_API_KEY` = master key LiteLLM

Variables :
- `LITELLM_URL` = `https://litellm.oxygn.dev/v1`
- `PRIMARY_MODEL` = `dsv4f`, `SMART_MODEL` = `zai-glm-5.2`, `FALLBACK_MODEL` = `MiniMax-M3`

Le label `ai-review` est créé par label-sync via `labels.yaml` (rien à faire).

## Modes d'échec (par conception)

- Evidence providers : advisory-only, `exit 0` + findings vides sur toute erreur (PR non trackée, render en cours, réseau) — ne peuvent pas faire échouer la review.
- Modèle en échec (primary + fallback) : `on_model_failure: notice` → commentaire visible "review impossible", jamais d'auto-approbation, n'échoue pas le job.
- MCP konflate inaccessible : le tool loop dégrade sans bloquer ; l'evidence provider émet findings vides.
- Timeout job : 35 min, aligné sur `tool_loop_wall_clock_sec: 600` + retries.

## Validation

1. `flate test ks` non applicable (rien sous `kubernetes/`) — vérif YAML lint actionlint si dispo.
2. Python : `python3 -m py_compile .github/scripts/*.py`.
3. Post-merge : pousser une PR de test (ou Renovate) → vérifier la review AI apparaît, avec section konflate rendered diff sur un bump de chart.
4. Re-review : ajouter le label `ai-review` sur une PR → nouvelle review, label retiré.
5. Vérifier `gh run watch` que le job tourne bien sur `home-ops-runner`.
