# Phoenix — Observabilité des agents IA + boucle d'amélioration continue

Spec validée le 2026-11-10 — périmètre `kubernetes/apps/observability/phoenix` + instrumentation du stack IA.

## 1. Contexte & objectifs

Le cluster héberge une dizaine d'agents IA (mainclaw/openclaw, opencode, hermes, foreman, devclaw, n8n, llmkube, memini, …) dont tout le trafic LLM passe par la gateway litellm (`kubernetes/apps/ai/litellm`). Aucune instrumentation LLM/agent aujourd'hui (aucune var `OTEL_*` dans le repo, pas de backend traces).

**Objectifs :**

1. Observabilité des agents : traces LLM (modèle, prompt, réponse, tokens, coût, latence) + traces agent-level (tool calls, sessions, workflows) quand le support natif existe.
2. Boucle d'amélioration continue : évaluations automatisées (LLM-as-judge) des traces récentes, datasets de régression construits depuis les échecs, expérimentations Phoenix rejouées sur dataset **avant** déploiement d'un changement de prompt/config.

**Non-objectifs (yagni assumés) :**

- Arize AX (cloud) — rejeté : les données agents ne quittent pas le home.
- OTel Collector central (reporté au §9 comme évolution prévue).
- Gestion centralisée des prompts dans Phoenix (playground/versioning).
- Instrumentation app-level exhaustive pour toutes les apps — couverture LLM par litellm suffit en MVP.
- Aucun remplacement de l'observabilité existante (metrics Prometheus de litellm et dashboards Grafana restent).

## 2. Décisions actées (résumé du brainstorming)

| Décision | Choix | Rationale |
|---|---|---|
| Backend traces | Arize Phoenix self-hosted OSS | OTLP natif, évals + datasets intégrés, léger, OSS |
| Périmètre MVP | Tout le stack IA, couverture LLM via litellm | Jour-1 à 100 % des apps sans toucher leur code |
| Stockage | PostgreSQL via composant `postgres` (CNPG) | SQLite viable à la volumétrie (~10²–10³ traces/j) mais CNPG coûte quasi rien ici : backups kopiur, pattern repo, zéro migration ultérieure |
| Placement repo | `kubernetes/apps/observability/phoenix` | Outillage transversal (comme victoria-logs), pas un app agent |
| UI | HTTPRoute envoy-internal + SSO OIDC Kanidm | Pattern `oidc-kanidm` du repo (sous-composante `envoy/`) |
| Auth app | `PHOENIX_ENABLE_AUTH=true` + clé système pour l'ingestion | Defense-in-depth (Envoy + Phoenix), requis pour l'API REST v1/évals |
| Pipeline | Direct OTLP/HTTP app→Phoenix | Pipeline court ; collector = dette documentée |

## 3. Architecture

```
apps ai (litellm, mainclaw, n8n, …)
   │  OTLP/HTTP : http://phoenix-svc.observability:6006/v1/traces
   │  header  Authorization: Bearer <clé système Phoenix>
   ▼
Phoenix (namespace observability) ── Postgres CNPG (composant postgres)
   │
   ├─ UI  : HTTPRoute envoy-internal (https://phoenix.<domain>) + SecurityPolicy OIDC Kanidm
   ├─ OTLP: Service `phoenix-svc` cluster-internal ports 6006 (http, `/v1/traces`) / 4317 (grpc) — pas d'exposition gateway
   └─ API : REST v1 — consommée par le CronJob phoenix-evals

phoenix-evals (CronJob nightly) ── litellm (LLM-as-judge)
   └─ écrit annotations (REST v1) + datasets dans Phoenix
```

Points clés :

- Phoenix est **hors chemin des requêtes** : export batch asynchrone ; Phoenix down ⇒ les exporters OTel perdent leurs batchs et les apps n'en sont pas impactées.
- L'ingestion OTLP reste cluster-internal (ingestion via le Service `phoenix-svc`, pas via la gateway) ; la protection est la clé système (`authorization` header) + la policy réseau par défaut du cluster.
- Single-tenant Phoenix (un foyer, un instance — le multi-tenant exigerait des instances séparées) ; projets = découpage par app, pas par orga.

## 4. Composants livrés

### 4.1 `kubernetes/apps/observability/phoenix` (infra)

- `ks.yaml` — Flux Kustomization (pattern repo).
- `app/ocirepository.yaml` — chart OCI officiel `oci://registry-1.docker.io/arizephoenix/phoenix-helm`, pin par **tag** (OCI chart = pas de digest selon la policy repo).
- `app/helmrelease.yaml` — HelmRelease : 1 replica, resources modestes (CPU < 500m, mem ~512Mi, à ajuster), env :
  - `PHOENIX_SQL_DATABASE_URL` (via secret CNPG)
  - `PHOENIX_ENABLE_AUTH=true`, `PHOENIX_SECRET` (external-secrets/1Password)
  - `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` (mot de passe admin initial, 1Password)
  - `PHOENIX_ENABLE_STRONG_PASSWORD_POLICY=true`
- `app/httpRoute.yaml` — envoy-internal + sous-composante `envoy/` du composant `oidc-kanidm` (OAuth2 client Kanidm provisionné : `kanidm-phoenix-oidc`).
- `app/externalsecret.yaml` — `PHOENIX_SECRET`, admin password, clé système Phoenix ; secret CNPG selon le pattern du composant `postgres`.
- Composants `postgres` (CloudNativePG + kopiur) et `kopiur/backup` selon le standard.

### 4.2 Instrumentation litellm (jour 1, couverture universelle)

Dans `kubernetes/apps/ai/litellm/app/` (config litellm) :

- `success_callback: ["otel"]` (+ `failure_callback` pour capturer aussi les échecs) ;
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://phoenix-svc.observability:6006` ;
- headers d'auth via `OTEL_EXPORTER_OTLP_HEADERS` (clé système Phoenix) ;
- le span porte l'identité de l'appelant (clés virtuelles existantes : `litellm-key-mainclaw`, `litellm-key-hermes`, `litellm-key-opencode`, …) → segmentation par agent côté Phoenix (project ou metadata selon mécanique confirmée au §6).

Résultat : **tous les appels LLM de tous les agents tracés sans modification des agents.**

### 4.3 Instrumentation agent-level native (incrémentale)

| App | Mécanisme | Statut MVP |
|---|---|---|
| mainclaw, devclaw (openclaw) | plugin `diagnostics-otel` (traces/metrics/logs OTLP natif) | activé |
| n8n | OTEL env vars natif | activé |
| hermes, foreman, opencode, llmkube, memini, lightrag, headroom | support OTel varié | **non MVP** — couvert côté LLM par litellm ; ajout app-level seulement si support natif confirmé (PR par app) |

Un projet Phoenix par agent quand le mécanisme de routing le permet ; projet par défaut sinon.

### 4.4 CronJob `phoenix-evals` (boucle d'amélioration)

- Exécution **nightly**, petite image python (Phoenix SDK + client litellm) ;
- workflow : dernières N traces par projet → évaluations **LLM-as-judge** (correctness, tool-use, latence anormale) via litellm → scores publiés comme **annotations REST v1** sur les spans ; traces échouées → incorporation dans un **dataset** Phoenix (corpus de régression, enrichi par incrément) ;
- usage : avant déploiement d'un changement d'agent (prompt/config), rejouer une **expérimentation** Phoenix sur le dataset → diff des scores avant/après ;
- secret : clé système Phoenix + clé litellm dédiée (coûts des juges tracés dans Phoenix).

### 4.5 Observabilité & alerting

- PrometheusRule : Phoenix indisponible, CNPG indisponible, échecs du CronJob ;
- Flux `alerts` (Provider/Alert) selon le standard du repo ;
- Grafana : pas de dashboard dédié en MVP (l'UI Phoenix fait le job) — lien croisé possible plus tard.

## 5. Flux de données (boucle complète)

1. Agent appelle litellm → span LLM (modèle, tokens, coût, latence, clé virtuelle) → Phoenix.
2. Si support natif : span agent (tool call, session via `session.id`) → Phoenix.
3. Nightly : `phoenix-evals` score les traces → annotations (REST v1) + dataset des échecs.
4. Humain analyse l'UI Phoenix (SSO Kanidm), labellise, enrichit le dataset.
5. Changement de prompt/config → expérimentation Phoenix sur le dataset → comparaison des scores → déploiement ou itération.
6. Retention : spans ≤ 90 j (30 ou 90 à trancher à l'implémentation d'après les options du chart/docs), datasets/annotations/expérimentations persistés indéfiniment.

## 6. Points à vérifier à l'implémentation (non bloquants au design)

- **Values du chart officiel** `phoenix-helm` (schéma `server.port`, support `auth.defaultAdminPassword`) — la chart évolue vite, lire les values au moment de la PR.
- **Routing par projet** Phoenix : mécanique exacte (attribut resource type `openinference.project.name` vs. projet par défaut) — à confirmer contre la doc du moment ; segmentation par litellm via la clé virtuelle en repli.
- **Retention** : env vars de rétention Phoenix actuelles (cf. docs Data Retention).
- **OIDC applicatif Phoenix** (envs `PHOENIX_OAUTH2_*`) : optionnel en plus d'Envoy SSO — activer seulement si (a) utile et (b) support Kanidm confirmé ; sinon l'auth Phoenix locale (admin + clés API) suffit.
- **Support OTel natif de chaque app « non MVP »** confirmé au cas par cas (README app, PR par PR).

## 7. Gestion d'erreurs

| Cas | Comportement |
|---|---|
| Phoenix indisponible | Les exporters OTel drop leurs batchs après limite de retry (défaut SDK) — apps non impactées ; ingestion reprend au retour |
| CronJob évals échoue | Échec visible (Prometheus/Flux) — repris au nightly suivant, pas de perte majeure (les traces restent disponibles) |
| CNPG down | Phoenix indisponible (UI + ingestion) — alerts standard ; restauration via backups kopiur |
| Spans invalides / ingestion partielle | Spans rejetés tracés dans les logs Phoenix ; re-export suit les retries des exporters |
| Secret manquant | ExternalSecret re-sync + workload restart (pattern repo) |

## 8. Tests & validations (par PR)

- `flate test ks --path ./kubernetes/apps` + `flate test hr` + `flate diff ks/hr` contre `origin/main` avant chaque push.
- **Smoke ingestion** : Job de debug pousse un span test (OTLP/HTTP) → projet visible dans Phoenix.
- **Smoke évals** : lancer le CronJob `phoenix-evals` manuellement (1 trace, 1 judge) → annotation + dataset vérifiés.
- **Auth** : accès UI via Kanidm SSO ; ingestion sans clé refusée ; ingestion avec clé acceptée.

## 9. Évolutions prévues (dette documentée, pas dans le MVP)

1. **OTel Collector central** (approche B du brainstorming) : buffering/sampling/multi-backend. Impact attendu : les apps changent **une seule** env var (`OTEL_EXPORTER_OTLP_ENDPOINT`), rien d'autre.
2. Instrumentation app-level pour hermes, foreman, opencode, … au support natif confirmé.
3. Gestion de prompts Phoenix si le besoin arrive.
4. Dashboards Grafana corrélant litellm metrics ↔ datasets/évals Phoenix si le besoin arrive.

## 10. Ordre d'implémentation (PRs)

1. **PR 1 — Infra Phoenix** : `kubernetes/apps/observability/phoenix` (chart, CNPG, secrets, HTTPRoute SSO, PrometheusRule) + smoke ingestion.
2. **PR 2 — litellm** : callback OTel + env vars → vérifier spans segmentés par agent.
3. **PR 3 — mainclaw + devclaw (openclaw `diagnostics-otel`) + n8n (OTEL env vars)**.
4. **PR 4 — CronJob `phoenix-evals`** (évals nightly + datasets) + README de la boucle d'amélioration.
5. **PR 5+n — instrumentation app-level incrémentale**, app par app selon support natif.

Chaque PR : `flate test/diff` + smoke test approprié + revue (branche + PR, pattern repo).
