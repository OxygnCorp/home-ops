# Phoenix Observability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Déployer Arize Phoenix self-hosted (OSS) comme backend de traces LLM/agents + activer l'export OTel de litellm/mainclaw/devclaw/n8n + boucle d'évals LLM-as-judge nightly, selon la spec `docs/superpowers/specs/2026-11-10-phoenix-observability-design.md`.

**Architecture:** Phoenix (chart Helm officiel OCI, 1 replica) dans `kubernetes/apps/observability/phoenix`, avec Postgres CNPG via le composant `postgres`, auth app (clé système pour l'ingestion OTLP, Secret `phoenix-secret` pré-existant via external-secrets), UI derrière `envoy-internal` + SSO Kanidm (composant `oidc-kanidm/envoy`). Les apps exportent en OTLP/HTTP direct vers `http://phoenix.observability:4318` (pas de collector — dette documentée §9 de la spec). Un CronJob `phoenix-evals` note les traces nightly via litellm et alimente datasets/annotations Phoenix.

**Tech Stack:** Flux (Kustomization/HelmRelease/OCIRepository), chart `phoenix-helm` v13.0.0 (appVersion 21.0.0), CloudNativePG, external-secrets + 1Password, Envoy Gateway SecurityPolicy OIDC, litellm OTel callback, openclaw plugin `diagnostics-otel`, n8n OTEL env vars, Python stdlib (CronJob).

**Spec:** `docs/superpowers/specs/2026-11-10-phoenix-observability-design.md` (branch `feat/phoenix-observability`, commit `2ac248bd9`)

## Global Constraints

- **Placement repo** : `kubernetes/apps/observability/phoenix` — namespace `observability` (dommage `kustomization.yaml` existant déjà `components: [../../components/alerts]`, s'y ajoute).
- **Secrets** : aucune valeur sensible dans Git. Tout via `ClusterSecretStore onepassword`. 1Password item `phoenix` (catégorie **API Credential**, cf. `virtualkeys/README.md`) avec champs (naming `ABC_DEF`, jamais kebab-case) :
  - `PHOENIX_SECRET` (généré : `openssl rand -base64 32`)
  - `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` (généré, 12+ caractères, upper/lower/digit/special — strong password policy)
  - `PHOENIX_SYSTEM_API_KEY` (créé post-déploiement en Task 1, step 16)
- **Chart** : OCI officiel `oci://registry-1.docker.io/arizephoenix/phoenix-helm` pin **par tag** (13.0.0 au moment de l'écriture ; les charts OCI sont exempt de la policy digest). Valeurs vérifiées contre `helm/values.yaml` upstream (main, version 13.0.0) : `replicaCount`, `postgresql.enabled` (groundhog2k — à **désactiver**, on branche CNPG), `persistence.enabled:false` (sqlite — à désactiver), `database.defaultRetentionPolicyDays`, `database.postgres.{db,host,port,user}`, `auth.secret[].valueFrom`, `auth.createSecret`, `server.enablePrometheus`, `service.type`, `additionalEnv` (supporte `valueFrom: secretKeyRef`), `image.{registry,repository,tag}` (tag défaut `version-21.0.0-nonroot`).
- **Ports Phoenix** : UI/API 6006, OTLP/HTTP 4318, OTLP/gRPC 4317. Ingestion = `http://phoenix.observability:4318` (cluster-internal, **pas** d'HTTPRoute sur 4318). Header ingestion : `authorization: Bearer <PHOENIX_SYSTEM_API_KEY>` (lowercase exigé par Phoenix).
- **Rétention** : spans/trace-data 90 jours (`database.defaultRetentionPolicyDays: 90`). Datasets/annotations/experimentations : non purgés.
- **Images container** : pin par `@sha256:` digest (policy repo). La digest python pour le CronJob est à relever à l'implémentation (step dédié). Le tag d'image Phoenix est porté par le chart OCI (exempt).
- **Domaine** : `phoenix.oxygn.dev`, OIDC Kanidm client `phoenix` (`kanidm-phoenix-oidc`), HTTPRoute name `phoenix` (cible `OIDC_ROUTE_NAME`).
- **Routing projet Phoenix** : attribut resource `openinference.project.name` quand l'app le permet (`OTEL_RESOURCE_ATTRIBUTES`), sinon projet défaut. litellm Day-1 : projet défaut, segmentation par clé virtuelle à confirmer post-smoke (§6 spec).
- **Pas d'OTel Collector** (spec §9) ; pas de dashboard Grafana MVP.
- **CNPG "down"** : couvert par `healthCheckExprs` (composant postgres + Kustomization failing → alerte Flux `components/alerts`), donc pas de règle Prometheus dédiée CNPG (déviation assumée vs spec §4.5, couverture équivalente).
- **Validation locale obligatoire avant chaque push** :
  ```bash
  mise exec -- flate test ks --path ./kubernetes/apps
  mise exec -- flate test hr --path ./kubernetes/apps
  git worktree add --detach /tmp/baseline origin/main
  mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
  mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
  git worktree remove /tmp/baseline --force
  ```
- **Git isolation** : chaque Task = une PR. Travailler dans `/home/opencode/projects/home-ops-phoenix-observability` (worktree existant, branche `feat/phoenix-observability`, contient le commit spec). Task 1 pousse cette branche + ouvre PR 1. Tasks 2-4 : nouvelle branche par PR (`git worktree add ../home-ops-phoenix-<sujet> origin/main -b feat/phoenix-<sujet>`), rebase sur origin/main, squash-merge via PR (convention repo). Ne jamais `git add -A` — n'additioner que les fichiers créés/modifiés.
- Les endpoints REST v1 Phoenix (annotations, datasets) et le routing projet sont des points à confirmer contre la doc du moment (arize.com/docs/phoenix/api-reference/rest) — steps de vérification explicites dans Tasks 1 et 4.

---

### Task 1: Infra Phoenix (PR 1)

**Files:**
- Create: `kubernetes/apps/observability/phoenix/ks.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/kustomization.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/ocirepository.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/helmrelease.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/externalsecret.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/externalsecret-otel.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/httproute.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/prometheusrule.yaml`
- Create: `kubernetes/apps/observability/phoenix/app/README.md`
- Modify: `kubernetes/apps/observability/kustomization.yaml` (ajouter `- ./phoenix/ks.yaml`)
- 1Password (manuel) : item `phoenix` (API Credential) avec `PHOENIX_SECRET` + `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD`.

**Interfaces:**
- Produces: Service `phoenix-server` (UI/API 6006, à confirmer par render — chaque step référence le nom réel après vérification), Service OTLP ports 4318/4317, Secret `phoenix-secret` (keys `PHOENIX_SECRET`, `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD`), Secret `phoenix-otel` (key `PHOENIX_SYSTEM_API_KEY`), CNPG Cluster `phoenix` + Secret `phoenix-app` (composant postgres), HTTPRoute `phoenix`, item 1Password `phoenix` dont le champ `PHOENIX_SYSTEM_API_KEY` est consommé par Tasks 2-4.
- Consumes: composants `postgres`, `oidc-kanidm/envoy`, `alerts` (inclus au niveau ns), ClusterSecretStore `onepassword`.

- [ ] **Step 1: Créer l'item 1Password `phoenix`**

Dans le vault `home-ops`, catégorie **API Credential** (obligatoire — les items "Password" ont un bug 1Password Connect à la mise à jour, cf. `virtualkeys/README.md`), champs :
- `PHOENIX_SECRET` = `openssl rand -base64 32`
- `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` = généré ≥12 caractères (upper+lower+chiffre+spécial)

- [ ] **Step 2: `ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: phoenix
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 13.0.0
  url: oci://registry-1.docker.io/arizephoenix/phoenix-helm
```

- [ ] **Step 3: `helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app phoenix
spec:
  dependsOn: []
  # ^ liste vide volontaire : le composant `postgres` patche ici sa dépendence
  #   cloudnative-pg (cf. kubernetes/apps/ai/lightrag/ks.yaml pour le pattern).
  chartRef:
    kind: OCIRepository
    name: *app
  interval: 1h
  values:
    replicaCount: 1
    # Strategy 3 (external DB) du chart : pas de groundhog2k in-chart, pas de
    # SQLite. Les données vivent dans le Cluster CNPG `phoenix`.
    postgresql:
      enabled: false
    persistence:
      enabled: false
    database:
      # Purge automatique des traces > 90j (spans + trace data). Les datasets,
      # annotations et experimentations ne sont pas couverts par la purge.
      defaultRetentionPolicyDays: 90
      postgres:
        db: phoenix
        host: phoenix-rw
        port: 5432
        user: phoenix
    auth:
      enableAuth: true
      enableStrongPasswordPolicy: true
      # cookies secure : l'UI passe par envoy-internal en HTTPS terminé Envoy.
      useSecureCookies: true
      # Secrets pré-existants fournis par external-secrets (policy repo :
      # aucun secret généré par le chart, tout vient de 1Password).
      createSecret: false
      secret:
        - key: PHOENIX_SECRET
          valueFrom:
            secretKeyRef:
              name: phoenix-secret
              key: PHOENIX_SECRET
        - key: PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
          valueFrom:
            secretKeyRef:
              name: phoenix-secret
              key: PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
        - key: PHOENIX_POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: phoenix-app
              key: password
    server:
      # /metrics Prometheus sur :9090 (PHOENIX_ENABLE_PROMETHEUS) — pour un
      # futur ServiceMonitor ; MVP: PrometheusRule "deployment down" via
      # kube-state-metrics seulement.
      enablePrometheus: true
    service:
      # NodePort par défaut du chart → ClusterIP (ingestion cluster-internal,
      # UI derrière envoy-internal).
      type: ClusterIP
    additionalEnv:
      - name: TZ
        value: Europe/Paris
    resources:
      requests:
        cpu: 100m
        memory: 512Mi
      limits:
        cpu: 1
        memory: 2Gi
```

- [ ] **Step 4: `externalsecret.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: phoenix
spec:
  # default documenté repo (12h) — external-secrets ne réécrit le Secret que
  # sur changement réel.
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: phoenix-secret
    creationPolicy: Owner
    template:
      data:
        PHOENIX_SECRET: "{{ .PHOENIX_SECRET }}"
        PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD: "{{ .PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD }}"
  data:
    - secretKey: PHOENIX_SECRET
      remoteRef:
        key: phoenix
        property: PHOENIX_SECRET
    - secretKey: PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
      remoteRef:
        key: phoenix
        property: PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD
```

- [ ] **Step 5: `externalsecret-otel.yaml`** (clé système pour l'ingestion — consommée par litellm/mainclaw/devclaw/n8n en Tasks 2-3 via leur propre ExternalSecret qui pointe le même item `phoenix`, et par le smoke test ci-dessous)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: phoenix-otel
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: phoenix-otel
    creationPolicy: Owner
    template:
      data:
        # Format OTEL_EXPORTER_OTLP_HEADERS (W3C) : espace URL-encodé %20,
        # le SDK OTel décode ; Phoenix exige le header lowercase `authorization`.
        OTEL_EXPORTER_OTLP_HEADERS: 'Authorization=Bearer%20{{ .PHOENIX_SYSTEM_API_KEY }}'
  data:
    - secretKey: PHOENIX_SYSTEM_API_KEY
      remoteRef:
        key: phoenix
        property: PHOENIX_SYSTEM_API_KEY
```

(Le champ `PHOENIX_SYSTEM_API_KEY` n'existe pas encore dans l'item — le Step 16 le crée. Entretemps l'ExternalSecret reste en `SecretSyncedError` : acceptable si le déploiement est suspendu, mais ordre recommandé : déployer l'infra (les deux premiers ExternalSecrets sync sans erreur), créer la clé système (Step 16), puis ajouter ce fichier (externalsecret-otel.yaml + sa ressource dans le kustomization.yaml) et le committer avec le reste.)

- [ ] **Step 6: `httproute.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: phoenix
spec:
  parentRefs:
    - name: envoy-internal
      namespace: network
  hostnames:
    - phoenix.oxygn.dev
  rules:
    - backendRefs:
        # Nom du Service du chart = "<release>-server"? CONFIRMÉ à l'étape
        # render (Step 8) — ajuster ici si le real name diffère.
        - name: phoenix-server
          kind: Service
          port: 6006
```

- [ ] **Step 7: `prometheusrule.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/monitoring.coreos.com/prometheusrule_v1.json
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: phoenix
spec:
  groups:
    - name: phoenix.rules
      rules:
        - alert: PhoenixDeploymentUnavailable
          expr: |-
            max by (namespace) (
              kube_deployment_status_replicas_available{namespace="observability", deployment=~"phoenix.*"}
            ) == 0
          for: 15m
          annotations:
            summary: Phoenix deployment has no available replica (UI + ingestion OTLP down, exporters drop their batches)
          labels:
            severity: warning
        - alert: PhoenixEvalsJobFailed
          # Le CronJob nightly tolère un échec ponctuel ; >2 échecs en 24h =
          # la boucle d'amélioration est bloquée (les traces restent
          # disponibles, elles attendent le nightly suivant).
          expr: |-
            increase(kube_job_status_failed{namespace="observability", job_name=~"phoenix-evals-.*"}[24h]) > 2
          for: 15m
          annotations:
            summary: phoenix-evals job failed more than twice in 24h — eval loop stalled
          labels:
            severity: warning
```

- [ ] **Step 8: Render check du chart (avant d'écrire kustomization)**

Commandes :
```bash
mise exec -- helm template phoenix oci://registry-1.docker.io/arizephoenix/phoenix-helm --version 13.0.0 \
  --set postgresql.enabled=false --set persistence.enabled=false \
  --set database.defaultRetentionPolicyDays=90 \
  --set database.postgres.db=phoenix --set database.postgres.host=phoenix-rw \
  --set database.postgres.port=5432 --set database.postgres.user=phoenix \
  --set auth.enableAuth=true --set auth.enableStrongPasswordPolicy=true \
  --set auth.createSecret=false --set auth.useSecureCookies=true \
  --set server.enablePrometheus=true --set service.type=ClusterIP > /tmp/phoenix-render.yaml
```
(puis inspecter les secrets/env via les `auth.secret.valueFrom` — la `-f <values yaml>` : voir alternative, extraire les 3 valueFrom manuellement — si le template exige un Secret logique in-chart plutôt que les valueFrom deploy env directement, **ajuster le helmrelease**.)

Vérifier :
1. Le **nom du Service server** (`grep -A3 "kind: Service"` → attendu `phoenix-server`) → corriger `httproute.yaml` si nécessaire.
2. Les env du deployment (grep `PHOENIX_`) : `PHOENIX_POSTGRES_HOST`/`DB`/`USER`/`PORT` présents, aucune `PHOENIX_SQL_DATABASE_URL` en double, les env `PHOENIX_SECRET`, `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD`, `PHOENIX_POSTGRES_PASSWORD` référencent bien `secretKeyRef` vers `phoenix-secret`/`phoenix-app`.
3. Les 2 secrets manquants à la création (phoenix-secret via ExternalSecret, phoenix-app via CNPG) → si le template reference une Auth secret autre nom, aligner.

Expected: render OK, pas d'erreur de coalescence `postgresql.enabled`/`persistence.enabled` ni de conflit `database.url`.

- [ ] **Step 9: `ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app phoenix
  labels:
    # Net-new CNPG cluster: plain initdb, no Barman recovery (see
    # kubernetes/flux/cluster/ks.yaml). Remove after the first scheduled backup.
    components.postgres/cnpg: init
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  components:
    - ../../../../components/postgres
    # Pas de kopiur/backup : phoenix n'a pas de PVC — tout l'état vit dans
    # CNPG (Barman weekly + WAL continu), le composant kopiur cible des PVC.
  dependsOn:
    - name: onepassword
      namespace: external-secrets
    - name: miroir-config
      namespace: miroir-system
  healthCheckExprs:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
  interval: 1h
  path: ./kubernetes/apps/observability/phoenix/app
  postBuild:
    substitute:
      APP: phoenix
      # oidc-kanidm/envoy : la SecurityPolicy générée cible le HTTPRoute
      # `${OIDC_ROUTE_NAME}` de ce namespace — soit `phoenix` (cf. httproute.yaml).
      APP_NAMESPACE: observability
      DOMAIN: oxygn.dev
      OIDC_CALLBACK: /oauth2/callback
      OIDC_DISPLAY_NAME: Phoenix
      OIDC_ROUTE_NAME: phoenix
      SUBDOMAIN: phoenix
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: observability
  timeout: 10m
  wait: false
```

NB: `dependsOn` reste vide — c'est le composant postgres qui patche sa dépendance cloudnative-pg dans le **HelmRelease** via `dependsOn: []`, pas dans ce KS.

- [ ] **Step 10: `app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./externalsecret.yaml
  - ./externalsecret-otel.yaml
  - ./helmrelease.yaml
  - ./httproute.yaml
  - ./ocirepository.yaml
  - ./prometheusrule.yaml
```

- [ ] **Step 11: `app/README.md`** — en regard de `litellm/app/README.md`. Contenu attendu (rédiger en anglais, style concis du repo) :
  1. Qu'est-ce que phoenix backend (traces LLM/agents), ingestion OTLP cluster-internal 4318/4317 protégée par clé système (header `authorization`), **hors chemin des requêtes** (exporters drop their batches if down).
  2. Credentials : 1Password item `phoenix` (`PHOENIX_SECRET`, `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD`, `PHOENIX_SYSTEM_API_KEY`), description de chaque ExternalSecret (`phoenix-secret` deploy env, `phoenix-otel` ingestion).
  3. Postgres : constitué par le composant `postgres` — CNPG Cluster `phoenix` (initdb, label `cnpg: init` à retirer après le 1er backup Barman, cf. README composant), retention spans 90j (`defaultRetentionPolicyDays`), datasets/annotations non purgés.
  4. Où noter les endpoints : UI `https://phoenix.oxygn.dev` (OIDC Envoy, kanidm client `phoenix`), ingestion `http://phoenix.observability:4318` (http) / 4317 (grpc). Comment ajouter un project côté exporter (`OTEL_RESOURCE_ATTRIBUTES=openinference.project.name=<app>`), comment la segmentation litellm prefère par key alias est documentée dans Task 2.
  5. Les 3 évolutions suivantes restent hors MVP : OTel Collector central (spec §9), instrumentation app-level pour les apps non-MVP (spec §4.3), dashboards Grafana corrélant litellm ↔ Phoenix (spec §9).
  6. Auth applicative Phoenix (`PHOENIX_OAUTH2_*`, auth.oauth2 du chart) : ** volontairement non activée** — l'Envoy SecurityPolicy couvre l'UI ; reactiver seulement si (a) utile et (b) support Kanidm confirmé (spec §6).

- [ ] **Step 12: Brancher dans le kustomization namespace** — modifier `kubernetes/apps/observability/kustomization.yaml` : ajouter `- ./phoenix/ks.yaml` aux `resources` (après `./victoria-logs/ks.yaml`, ordre alphabétique non strict — pattern en place colonnes).

- [ ] **Step 13: flate test + diff local**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps/observability/phoenix
mise exec -- flate test hr --path ./kubernetes/apps
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: 0 erreur schema ; diff montre l'ajout phoenix (OCIRepository, HelmRelease, CNPG Cluster, ExternalSecrets, HTTPRoute, PrometheusRule, SecurityPolicy envoy générée).

- [ ] **Step 14: Commit + push + PR 1**

```bash
git add kubernetes/apps/observability/phoenix kubernetes/apps/observability/kustomization.yaml
git commit -m "feat(phoenix): add Arize Phoenix self-hosted tracing backend (infra)"
git push -u origin feat/phoenix-observability
gh pr create --fill --title "feat(phoenix): add Arize Phoenix self-hosted tracing backend (infra)" \
  --body "PR 1/4 of the Phoenix observability plan. Infra only: chart, CNPG, ExternalSecrets, HTTPRoute+OIDC, PrometheusRule. Ingestion app wiring lands in PR 2-3."
```

- [ ] **Step 15: Déploiement + première connexion admin**

Attendre le déploiement (`flux reconcile kustomization phoenix -n observability` pour forcer, ou automatique au push). Vérifier :
```bash
flux get hr phoenix -n observability -o yaml | grep -A3 "conditions"   # Ready True
kubectl get cluster phoenix -n observability                          # Ready
```
1re connexion UI `https://phoenix.oxygn.dev` (redirect Kanidm) → login admin au mot de passe 1Password → créer un compte admin personnalisé si voulu (l'admin est un compte "système" local). **Si le mot de passe admin initial est rejeté** (erreur "strong password policy"), forcer une re-génération du champ 1Password + `kubectl annotate externalsecret phoenix -n observability force-sync=$(date +%s)` + restart deployment.

- [ ] **Step 16: Créer la clé système Phoenix → 1Password**

Dans UI Phoenix → Settings → API Keys → créer une **System Key** (type system, description `ingestion`). Copier la clé `sk-...` dans l'item 1Password `phoenix`, champ `PHOENIX_SYSTEM_API_KEY`. Forcer la sync :
```bash
kubectl annotate externalsecret phoenix-otel -n observability force-sync=$(date +%s)
kubectl get secret phoenix-otel -n observability -o jsonpath='{.data.PHOENIX_SYSTEM_API_KEY}' | base64 -d   # non-vide
```

- [ ] **Step 17: Smoke test ingestion OTLP**

```bash
KEY=$(kubectl get secret -n observability phoenix-otel -o jsonpath='{.data.PHOENIX_SYSTEM_API_KEY}' | base64 -d)
kubectl run -n observability smoke-otlp --rm -i --restart=Never \
  --image=docker.io/library/python:3.13 \
  --env="PHOENIX_SYSTEM_API_KEY=${KEY}" -- bash -c 'pip -q install opentelemetry-sdk opentelemetry-exporter-otlp-proto-http && python3 -' <<'PY'
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
provider = TracerProvider(resource=Resource.create({
    "service.name": "smoke-otlp",
    "openinference.project.name": "smoke",
}))
provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(
    # Phoenix expose l'OTLP HTTP standard sur /v1/traces (port 4318)
    endpoint="http://phoenix.observability:4318/v1/traces")))
with trace.get_tracer("smoke-otlp").start_as_current_span("smoke/hello"):
    pass
provider.shutdown()
print("smoke OK")
PY
```
Note : `OTLPSpanExporter(endpoint=...)` est explicite ici pour un test autonome ; en prod, les app se basent sur les env `OTEL_EXPORTER_OTLP_*` (endpoint protocole headers), dont `OTEL_EXPORTER_OTLP_HEADERS` porte l'`Authorization`.

Vérifier aussi l'**ingestion refusée sans clé** :
```bash
kubectl run -n observability smoke-otlp-noauth --rm -i --restart=Never \
  --image=docker.io/library/python:3.13 -- bash -c 'curl -s -o /dev/null -w "%{http_code}\n" \
  -X POST http://phoenix.observability:4318/v1/traces -H "content-type: application/x-protobuf" \
  --data-binary @/dev/null'
# attendu: 401/403 (pas 200)
```
Expected: UI `https://phoenix.oxygn.dev` → projet `smoke` visible avec le span `smoke/hello`.

- [ ] **Step 18: PR 1 → mergees**

Analyse après CI (konflate status + AI review) ; squash-merge.

- [ ] **Step 19: Retirer le label `components.postgres/cnpg: init` (post-backup)**

Après le premier backup Barman scheduled (dimanche 01:30) ou un `Backup` CR one-shot :
```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata: { name: phoenix-initial, namespace: observability }
spec: { cluster: { name: phoenix }, method: barmanObjectStore }
EOF
# attendre le backup terminé, puis :
git -C /home/opencode/projects/home-ops-phoenix-observability grep -n "cnpg: init" -- kubernetes/apps/observability/phoenix/ks.yaml
# retirer le label du ks.yaml (edit), commit + push
```
(Selon le README composant postgres : ce label force initdb à chaque rebuild du Cluster CR, contrevient à la recovery Barman. Commit séparé possible immédiatement après le backup one-shot ; sinon laisse dormir jusqu'au prochain touch de phoenix.)

---
### Task 2: Instrumentation litellm OTLP (PR 2)

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml` (litellmSettings.success_callback + env OTLP)
- Modify: `kubernetes/apps/ai/litellm/app/externalsecret.yaml` (append doc `phoenix-otel`)
- Create: `kubernetes/apps/observability/phoenix/app/README.md` — append "Day-1 wiring: litellm exports OTLP → Phoenix" (optionnel, cohérence cross-app)

**Interfaces:**
- Consumes: Service `phoenix.observability:4318` + Secret `phoenix-otel` (Task 1), item 1Password `phoenix`.
- Produces: spans litellm OTLP/HTTP visibles dans Phoenix projet défaut (litellm), callback ajouté au CR existant sans autre mod.

- [ ] **Step 1: Modifier `litellmproxy.yaml` — callbacks**

Dans `spec.litellmSettings`. (Extraits avec le contexte clé, à insérer dans le CR existant — indentation `spec.litellmSettings.*` au plan : 4 espaces.) :
```yaml
    callbacks:
      - prometheus
      - hooks.session_hook.service_session_injector
    success_callback:
      - prometheus
      # Phoenix ingestion — OTLP/HTTP direct (spec §4.2). lossless batching:
      # export async, Phoenix down ⇒ exporters drop par retry-limit (les
      # apps ne sont pas impactées — spec §7).
      - otel
    failure_callback:
      - prometheus
      # Capturer aussi les appels LLM en erreur (spans 4xx/5xx) pour alimenter
      # les datasets d'échecs de la boucle d'évals (Task 4 / spec §4.4).
      - otel
```

- [ ] **Step 2: env OTLP dans `litellmproxy.yaml` `spec.env` (adapté au schema litellmoperator)**

```yaml
    - name: TZ
      value: Europe/Paris
    - name: LITELLM_LOG
      value: INFO
    - name: LITELLM_MODE
      value: PRODUCTION
    # --- Phoenix OTLP ingestion (kubernetes/apps/observability/phoenix) ---
    - name: OTEL_EXPORTER_OTLP_PROTOCOL
      value: http/protobuf
    - name: OTEL_EXPORTER_OTLP_ENDPOINT
      value: http://phoenix.observability:4318
    - name: OTEL_EXPORTER_OTLP_HEADERS
      valueFrom:
        secretKeyRef:
          name: phoenix-otel
          key: OTEL_EXPORTER_OTLP_HEADERS
```
(la (`spec.env` garde son format liste — cf. le schema de `litellmproxy.yaml` ; le pattern `envFrom: litellm-secret` est maintenu.)

- [ ] **Step 3: Append doc `phoenix-otel` dans `litellm/app/externalsecret.yaml`**

Réutiliser le même document que Task 1 Step 5 (ExternalSecret `phoenix-otel` target `phoenix-otel`, remoteRef key `phoenix` property `PHOENIX_SYSTEM_API_KEY`, template `OTEL_EXPORTER_OTLP_HEADERS: 'Authorization=Bearer%20{{ .PHOENIX_SYSTEM_API_KEY }}'`).

- [ ] **Step 4: flate + commit + PR 2**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm
# baseline diff (cf. Global Constraints pour le workflow worktree /tmp/baseline)
git worktree add ../home-ops-phoenix-litellm origin/main -b feat/phoenix-litellm-otel  # (si PR 1 mergée — sinon base feat/phoenix-observability)
# créer/modifier dans le nouveau worktree les fichiers listés en tête de Task 2
git add kubernetes/apps/ai/litellm/app/litellmproxy.yaml kubernetes/apps/ai/litellm/app/externalsecret.yaml
git commit -m "feat(litellm): export LLM call traces to Phoenix via native OTel callback"
git push -u origin feat/phoenix-litellm-otel
gh pr create --fill
```

- [ ] **Step 5: Smoke test post-déploiement (industrie critique)**

1. Rollout litellm complet, puis appeler un model via litellm (`curl http://litellm.ai.svc.cluster.local:4000/v1/chat/completions -H "Authorization: Bearer <une clé virtuelle>" -d '{"model":"dsv41f","messages":[{"role":"user","content":"ping"}]}'`).
2. Vérifier dans l'UI Phoenix (projet défaut) : nouveaux spans LLM avec modèle/tokens/latence, et l'attribut matérialisant la clé virtuelle (key alias). **Noter le nom exact de cet attribut** en inspectant un span dans l'UI et **l'enregistrer dans le README Phoenix** (`kubernetes/apps/observability/phoenix/app/README.md`) — la segmentation par agent s'appuie dessus pour les évals (Task 4 / spec §4.2/§6). Projet dédié litellm = MVP rejeté, projet défaut assumé.
3. Vérifier que les callbacks Prometheus existants restent opérationnels et que les pods litellm ne loggent pas d'erreur côté `opentelemetry` : `kubectl logs -n ai <pod litellm> | grep -i otel` (attendu : pas d'export failure en boucle ; un `ETELEM`/timeout ponctuel est tolérable, Phoenix étant hors chemin).

---
### Task 3: mainclaw + devclaw (openclaw `diagnostics-otel`) + n8n OTEL (PR 3)

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json` (plugin enable)
- Modify: `kubernetes/apps/ai/mainclaw/app/helmrelease.yaml` (env OTLP)
- Modify: `kubernetes/apps/ai/mainclaw/app/externalsecret.yaml` (append doc `phoenix-otel`)
- Modify: `kubernetes/apps/ai/devclaw/app/resources/openclaw.json` (plugin enable — même image openclaw que mainclaw, même mécanique)
- Modify: `kubernetes/apps/ai/devclaw/app/helmrelease.yaml` (env OTLP)
- Modify: `kubernetes/apps/ai/devclaw/app/externalsecret.yaml` (append doc `phoenix-otel`)
- Modify: `kubernetes/apps/ai/n8n/app/helmrelease.yaml` (env OTEL)
- Modify: `kubernetes/apps/ai/n8n/app/externalsecret.yaml` (append doc `phoenix-otel`)

**Interfaces:**
- Consumes: Service `phoenix.observability:4318`, Secret `phoenix-otel` (Task 1 pattern, recopié dans le namespace `ai` via l'ExternalSecret doc `phoenix-otel`), plugin openclaw `diagnostics-otel`.
- Produces: traces agent-level mainclaw + devclaw (tool calls, sessions) + traces n8n workflows dans Phoenix (projets `mainclaw`/`devclaw`/`n8n`), en complément des traces LLM litellm (Task 2).

- [ ] **Step 1: doc plugin openclaw (vérifier la shape exacte à l'écriture)**

Consulter `https://github.com/openclaw/openclaw/tree/main/plugins/diagnostics-otel` (ou doc bundled: `node /app/openclaw.mjs plugin show diagnostics-otel` depuis le pod mainclaw — même image que devclaw) pour connaître les clés de config attendues (`endpoint`, `protocol`, `headers`?). Le plugin étend les env OTel standard si présentes — sinon config explicites dans `openclaw.json`.

- [ ] **Step 2: `openclaw.json` — activer le plugin (mainclaw ET devclaw)**

Dans les deux fichiers `resources/openclaw.json` : ajouter `diagnostics-otel` dans `plugins.allow` en gardant l'ordre alphabétique (dans mainclaw comme dans devclaw : entre `browser` et `discord`) ; dans `plugins.entries` (les deux) :
```json
      "diagnostics-otel": {
        "enabled": true,
        "config": {
          "endpoint": "http://phoenix.observability:4318",
          "protocol": "http"
        }
      },
```
(les clés de config sont à **adapter** au résultat du Step 1 ; si le plugin honore les env standard, remplacer la config par `{}` et laisser passer par env.)

- [ ] **Step 3: `mainclaw/app/helmrelease.yaml` — env** (container `openclaw`, en bloc `env:`)

```yaml
            env:
              # ... (env existantes conservées) ...
              # Phoenix OTLP ingestion (app kubernetes/apps/observability/phoenix)
              OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
              OTEL_EXPORTER_OTLP_ENDPOINT: http://phoenix.observability:4318
              # Routing Phoenix: projet `mainclaw` via l'attribut openinference
              OTEL_RESOURCE_ATTRIBUTES: openinference.project.name=mainclaw
              OTEL_EXPORTER_OTLP_HEADERS:
                valueFrom:
                  secretKeyRef:
                    name: phoenix-otel
                    key: OTEL_EXPORTER_OTLP_HEADERS
```
⚠️ annotation `secret.reloader.stakater.com/reload: "mainclaw-secret, mainclaw-config"` — si le secret `phoenix-otel` change (rotation clé), un rollout manuel est requis (le reloader ne surveille que mainclaw-*). Le refreshInterval 12h + rotation clé système documentée (bas fréquence), pas d'automatisation MVP.

- [ ] **Step 4: `mainclaw/app/externalsecret.yaml` — append doc `phoenix-otel`** (identique à Task 1 Step 5)

- [ ] **Step 5: `devclaw/app/helmrelease.yaml` — env** (container `app`, en bloc `env:` — même campagne d'env que mainclaw Step 3)

```yaml
              # Phoenix OTLP ingestion (app kubernetes/apps/observability/phoenix)
              OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
              OTEL_EXPORTER_OTLP_ENDPOINT: http://phoenix.observability:4318
              # Routing Phoenix: projet `devclaw` via l'attribut openinference
              OTEL_RESOURCE_ATTRIBUTES: openinference.project.name=devclaw
              OTEL_EXPORTER_OTLP_HEADERS:
                valueFrom:
                  secretKeyRef:
                    name: phoenix-otel
                    key: OTEL_EXPORTER_OTLP_HEADERS
```
⚠️ annotation `secret.reloader.stakater.com/reload: "devclaw-secret, devclaw-config"` — même caveat de rotation que mainclaw (rollout manuel si la clé change).

- [ ] **Step 6: `devclaw/app/externalsecret.yaml` — append doc `phoenix-otel`** (identique à Task 1 Step 5)

- [ ] **Step 7: `n8n/app/helmrelease.yaml` — env** (container `main`, en bloc `env:`)

```yaml
              # Phoenix OTLP ingestion (kubernetes/apps/observability/phoenix)
              OTEL_EXPORTER_OTLP_PROTOCOL: http/protobuf
              OTEL_EXPORTER_OTLP_ENDPOINT: http://phoenix.observability:4318
              OTEL_RESOURCE_ATTRIBUTES: openinference.project.name=n8n
              OTEL_EXPORTER_OTLP_HEADERS:
                valueFrom:
                  secretKeyRef:
                    name: phoenix-otel
                    key: OTEL_EXPORTER_OTLP_HEADERS
```
⚠️ Vérifier à l'implémentation les noms de env exacts n8n (https://docs.n8n.io — recherche "OpenTelemetry") : n8n expose ses propres variables (`N8N_OTEL_*`?) en versions récentes ; si la doc n8n expose des vars spécifiques, les déclarer à la place/en complément du standard `OTEL_*`. (n8n est en 3.0.1, doc actuelle : https://docs.n8n.io/hosting/monitoring/ opentelemetry-instrumentation).

- [ ] **Step 8: `n8n/app/externalsecret.yaml` — append doc `phoenix-otel`** (identique)

- [ ] **Step 9: flate + commit + push + PR 3** (même mécanique que Task 2 Step 4)

- [ ] **Step 10: Smoke test agent-level spans**

1. Déclencher une action mainclaw (message discord ou commande gateway) → attendre le batch export → voir dans Phoenix projet `mainclaw` des spans non-LLM (tool calls, session) + LLM spans déjà via litellm.
2. Déclencher une action devclaw (idem) → vérifier spans projet `devclaw` (spans non-LLM agent-level).
3. Déclencher un workflow n8n → vérifier spans projet `n8n` (workflow execution, ai-nodes).
4. Confirmer `kubectl logs -n ai deployment/mainclaw -c openclaw` et `kubectl logs -n ai deployment/devclaw -c app` **sans erreur** de type `otel` / `diagnostics-otel` ; pareil pour n8n.

---
### Task 4: CronJob `phoenix-evals` — boucle d'amélioration (PR 4)

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/virtualkeys/phoenix-evals.yaml` (LiteLLMVirtualKey + PushSecret)
- Modify: `kubernetes/apps/ai/litellm/app/virtualkeys/kustomization.yaml`
- Create: `kubernetes/apps/observability/phoenix/evals/kustomization.yaml`
- Create: `kubernetes/apps/observability/phoenix/evals/cronjob.yaml`
- Create: `kubernetes/apps/observability/phoenix/evals/resources/evals.py`
- Create: `kubernetes/apps/observability/phoenix/evals/externalsecret.yaml`
- Create: `kubernetes/apps/observability/phoenix/evals/README.md`
- Modify: `kubernetes/apps/observability/phoenix/ks.yaml` (ajoute Kustomization `phoenix-evals`, dependsOn `phoenix`)

**Interfaces:**
- Consumes: REST Phoenix v1 + clé système `PHOENIX_SYSTEM_API_KEY` (item `phoenix`) ; litellm OpenAI-compatible `http://litellm.ai.svc.cluster.local:4000/v1` avec virtual key `KEY_PHOENIX_EVALS` (item `litellm`) ; traces générées Task 2.
- Produces: CronJob `phoenix-evals` (ns observability), 1Password item `litellm` field `KEY_PHOENIX_EVALS` (auto par PushSecret), Secret `phoenix-evals` (keys `PHOENIX_SYSTEM_API_KEY`, `LITELLM_API_KEY`).

- [ ] **Step 1: `virtualkeys/phoenix-evals.yaml`** (pattern `virtualkeys/memini.yaml`)

```yaml
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMVirtualKey
metadata:
  name: phoenix-evals
spec:
  proxyRef: litellm
  keyAlias: Phoenix-Evals
  # Pas de teamID: le juge litellm ne consomme pas d'outils MCP à jour —
  # cf. virtualkeys/README.md (le pattern "No teamID").
  secretName: litellm-key-phoenix-evals
  secretKey: api-key
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/pushsecret_v1alpha1.json
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: phoenix-evals
spec:
  refreshInterval: 1h
  secretStoreRefs:
    - name: onepassword
      kind: ClusterSecretStore
  selector:
    secret:
      name: litellm-key-phoenix-evals
  data:
    - match:
        secretKey: api-key
        remoteRef:
          remoteKey: litellm
          property: KEY_PHOENIX_EVALS
```

- [ ] **Step 2: Modifiées `virtualkeys/kustomization.yaml`** — ajouter `- ./phoenix-evals.yaml`

- [ ] **Step 3: `evals/externalsecret.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: phoenix-evals
spec:
  refreshInterval: 12h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: phoenix-evals
    creationPolicy: Owner
  data:
    # E+/clé d'inscription système Phoenix (annotations REST v1)
    - secretKey: PHOENIX_SYSTEM_API_KEY
      remoteRef:
        key: phoenix
        property: PHOENIX_SYSTEM_API_KEY
    # Virtual key litellm via PushSecret (cf. virtualkeys/README.md):
    # le juge appelle litellm comme un agent normal; ses appels sont
    # eux-mêmes tracés dans Phoenix (attribut KEY_ALIAS=Phoenix-Evals),
    # ce qui permet de mesurer le cstet du LLM-as-judge dans Phoenix.
    - secretKey: LITELLM_API_KEY
      remoteRef:
        key: litellm
        property: KEY_PHOENIX_EVALS
```

- [ ] **Step 4: Digest de l'image python**

```bash
mise exec -- crane digest docker.io/library/python:3.13
# fallback si crane absent : docker buildx imagetools inspect
```
Noter la digest en commentaire `# renovate: image=docker.io/library/python tag=3.13`? (pattern repo : Renovate regroupe les updates digest.)

- [ ] **Step 5: Vérifier les endpoints REST v1 Phoenix (docs du moment)**

Lire `https://arize.com/docs/phoenix/api-reference/rest` (ou OpenAPI Swagger embarqué `https://phoenix.oxygn.dev/api/...`).**Concilier** les constants suivants de `evals.py` avec la doc :
- List spans : `GET /v1/projects/{project_identifier}` + `GET /v1/projects/{id}/spans` (retry cursor).
- Annotations spans en bulk : `POST /v1/span_annotations` (payload `{data: [{"span_id":..., "name":..., "score":..., "label":..., "annotator_kind": "LLM", "explanation":...}]})`.
- Datasets : `GET /v1/datasets/{name}` + insertion exemples `POST /v1/datasets/{id}/insert_examples`? (en créer le dataset s'il n'existe pas via `POST /v1/datasets`).

Baser le Step 6 sur les scripts/paths confirmés ; s'adapter si les routes diffèrent.

- [ ] **Step 6: `evals/resources/evals.py`** — script stdlib-only (pas de pip install, pattern foreman-watcher). Skeleton complet à adapter journées endpoints du Step 5 :

```python
#!/usr/bin/env python3
"""phoenix-evals — nightly LLM-as-judge sur les traces Phoenix.

1. Récupère le projet Phoenix + les derniers N spans (traces complètes).
2. Fait évaluer chaque trace par litellm (LLM-as-judge).
3. Publie les scores comme annotations Phoenix (REST v1, annotator_kind LLM).
4. Ajoute les traces en échec à un dataset Phoenix de régression
   (enrichi par incrément d'exécution, jamais recréé).
"""
import json
import os
import sys
import urllib.error
import urllib.request

PHOENIX = os.environ["PHOENIX_BASE_URL"].rstrip("/")          # http://phoenix.observability:6006
PHX_API_KEY = os.environ["PHOENIX_SYSTEM_API_KEY"]
LITELLM_BASE = os.environ["LITELLM_BASE_URL"].rstrip("/")    # http://litellm.ai.svc.cluster.local:4000
LITELLM_KEY = os.environ["LITELLM_API_KEY"]
LITELLM_MODEL = os.environ["PHOENIX_EVALS_JUDGE_MODEL"]      # par défaut dsv41f
PROJECT = os.environ["PHOENIX_EVALS_PROJECT"]                # projet défaut du MVP litellm
DATASET_NAME = os.environ["PHOENIX_EVALS_DATASET"]           # "phoenix-evals-failures"
MAX_SPANS = int(os.environ["PHOENIX_EVALS_MAX_SPANS"])       # 50 (modéré)
FAIL_THRESHOLD = float(os.environ["PHOENIX_EVALS_THRESHOLD"])# score < 0.5 → dataset

def req(method, url, token, body=None):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("authorization", f"Bearer {token}")
    r.add_header("content-type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"{method} {url} -> {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
        raise

def judge(span):
    """Retourne (score 0..1, label, explanation)."""
    input_data = (span.get("attributes") or {}).get("input", {}).get("value", "")
    output_data = (span.get("attributes") or {}).get("output", {}).get("value", "")
    prompt = f"""You are grading a single LLM agent exchange.
User request: {input_data}
Assistant/tool response: {output_data}
Score correctness & tool-use sanity on 0-1. Answer STRICT JSON {{"score": <float>, "reason": "<one line>"}}"""
    resp = req("POST", f"{LITELLM_BASE}/v1/chat/completions", LITELLM_KEY, {
        "model": LITELLM_MODEL,
        "messages": [
            {"role": "system", "content": "You are a terse LLM-as-judge; output strict JSON only."},
            {"role": "user", "content": prompt},
        ],
        "temperature": 0.0,
    })
    try:
        payload = json.loads(resp["choices"][0]["message"]["content"])
        return float(payload["score"]), str(payload["reason"])
    except (KeyError, ValueError, TypeError) as e:
        # Le juge a répondu veut pas de JSON: on ne prend pas de risque d'annotation.
        print(f"judge parse error ({e}); skipping span", file=sys.stderr)
        return None, None

def main():
    projects = req("GET", f"{PHOENIX}/v1/projects", PHX_API_KEY)
    match = [p for p in projects.get("data", []) if p.get("name") == PROJECT]
    if not match:
        sys.exit(f"projet {PROJECT!r} introuvable dans Phoenix")
    project_id = match[0]["id"]

    spans = req("GET", f"{PHOENIX}/v1/projects/{project_id}/spans", PHX_API_KEY).get("data", [])[-MAX_SPANS:]
    annotations, failures = [], []
    for span in spans:
        score, reason = judge(span)
        if score is None:
            continue
        annotations.append({
            "span_id": span["context"]["span_id"],
            "name": "quality",
            "score": score,
            "label": "good" if score >= FAIL_THRESHOLD else "bad",
            "annotator_kind": "LLM",
            "explanation": reason,
        })
        if score < FAIL_THRESHOLD:
            failures.append({"input": {"value": (span['attributes'] or {}).get('input', {}).get('value', ''),
                                        "mime_type": "text"},
                             "output": {"value": (span['attributes'] or {}).get('output', {}).get('value', ''),
                                         "mime_type": "text"}})
    if annotations:
        req("POST", f"{PHOENIX}/v1/span_annotations", PHX_API_KEY, {"data": annotations})
    if failures:
        # Datasets: create-if-missing puis insertion delta (idempotent-ish).
        expected = req("GET", f"{PHOENIX}/v1/datasets/{DATASET_NAME}", PHX_API_KEY).get("data")
        if not expected:
            expected = req("POST", f"{PHOENIX}/v1/datasets", PHX_API_KEY,
                           {"name": DATASET_NAME, "description": "Regression dataset, auto-fed by nightly failures"}).get("data")
        req("POST", f"{PHOENIX}/v1/datasets/{expected['id']}/insert_examples", PHX_API_KEY,
            {"examples": [{"input": f["input"], "output": f["output"]} for f in failures]})
    print(f"phoenix-evals done: {len(annotations)} annotations, {len(failures)} dataset rows added.")

if __name__ == "__main__":
    main()
```
NB : les paths/payloads sont le meilleur état de la doc REST v1 au moment de la rédaction — le Step 5 (lecture doc du jour) fait foi et corrige les décalages avant le premier run. Le juge est un modèle litellm normal : ses appels sont eux-mêmes tracés dans Phoenix sous la clé `Phoenix-Evals`, ce qui mesure le coût du LLM-as-judge.

- [ ] **Step 7: `evals/cronjob.yaml`** (pattern `foreman/watcher/cronjob.yaml`)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/batch/v1/cronjob.json
apiVersion: batch/v1
kind: CronJob
metadata:
  name: phoenix-evals
spec:
  # Nightly 03:02 Europe/Paris — après le pic d'usage des agents soir.
  schedule: "2 3 * * *"
  timeZone: Europe/Paris
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3       # la règle Prometheus PhoenixEvalsJobFailed lit kube_job_status_failed
  jobTemplate:
    spec:
      backoffLimit: 0
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: app
              # renovate: image=docker.io/library/python tag=3.13
              image: docker.io/library/python:3.13@sha256:<DIGEST-du-Step-4>
              command: ["python3", "/config/evals.py"]
              env:
                - name: TZ
                  value: Europe/Paris
                - name: PHOENIX_BASE_URL
                  value: http://phoenix.observability:6006
                - name: LITELLM_BASE_URL
                  value: http://litellm.ai.svc.cluster.local:4000
                - name: PHI_PRETTY
                  value: "0"
                - name: PHOENIX_EVALS_JUDGE_MODEL
                  value: dsv41f
                - name: PHOENIX_EVALS_PROJECT
                  value: default      # projet défaut litellm (Task 2, MVP)
                - name: PHOENIX_EVALS_DATASET
                  value: phoenix-evals-failures
                - name: PHOENIX_EVALS_MAX_SPANS
                  value: "50"
                - name: PHOENIX_EVALS_THRESHOLD
                  value: "0.5"
                - name: PHOENIX_SYSTEM_API_KEY
                  valueFrom:
                    secretKeyRef:
                      name: phoenix-evals
                      key: PHOENIX_SYSTEM_API_KEY
                - name: LITELLM_API_KEY
                  valueFrom:
                    secretKeyRef:
                      name: phoenix-evals
                      key: LITELLM_API_KEY
              resources:
                requests:
                  cpu: 10m
                  memory: 64Mi
                limits:
                  memory: 256Mi
              securityContext:
                allowPrivilegeEscalation: false
                readOnlyRootFilesystem: true
                capabilities:
                  drop:
                    - ALL
              volumeMounts:
                - name: config
                  mountPath: /config
                  readOnly: true
                - name: tmp
                  mountPath: /tmp
          volumes:
            - name: config
              configMap:
                name: phoenix-evals-config
            - name: tmp
              emptyDir: {}

- [ ] **Step 8: `evals/kustomization.yaml`** (pattern mainclaw configMapGenerator)

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./cronjob.yaml
  - ./externalsecret.yaml
configMapGenerator:
  - name: phoenix-evals-config
    files:
      - evals.py=./resources/evals.py
generatorOptions:
  disableNameSuffixHash: true
```

- [ ] **Step 9: Modifiées `phoenix/ks.yaml`** — ajouter au-dessus (2nd doc):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: phoenix-evals
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: phoenix-evals
  dependsOn:
    - name: phoenix
  interval: 1h
  path: ./kubernetes/apps/observability/phoenix/evals
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: observability
  wait: false
```

- [ ] **Step 10: flate + commit + PR 4** (mécanique Tasks 2-3)

- [ ] **Step 11: Smoke test évals (1 span, 1 judge)**

Forcer une exécution :
```bash
kubectl create job -n observability --from=cronjob/phoenix-evals phoenix-evals-manual
kubectl get job/pods -n observability -l job-name=phoenix-evals-manual -w
kubectl logs -n observability job/phoenix-evals-manual
kubectl delete job -n observability phoenix-evals-manual
```
Puis vérifier dans l'UI Phoenix :
- annotations `quality` (LLM) visibles sur les traces récentes du projet évalué ;
- dataset `phoenix-evals-failures` créé/enrichi (rows examples).
Si une route `/v1/...` renvoie 404/422 → corriger `evals.py` selon les paths confirmés au Step 5 et re-run.

- [ ] **Step 12: PR 4 → mergees. Démo UI**: rebooter le loop : expérimentation sur le dataset Phoenix (dataset > run experiment) → diff les scores (courbe baseline). Documenter à 1 bout le loop complet dans `evals/README.md` (rédiger : workflow chagement daily, comment insérer un labelling en UI, comment lancer une experiment la veille d'un changement de prompt ; spec §4.4/§5).

---

## Séquencement & PR mapping (spec §10)

| Task | PR | Contenu | Smoke |
|---|---|---|---|
| 1 | PR 1 | Infra Phoenix + SSO + CNPG + clés + alerts | ingestion OTLP ok, UI SSO ok, no-key refusée |
| 2 | PR 2 | litellm OTel callback | spans litellm (aliases, tokens) visibles |
| 3 | PR 3 | mainclaw + devclaw `diagnostics-otel` + n8n OTEL | spans agent-level mainclaw/devclaw + workflows n8n |
| 4 | PR 4 | CronJob `phoenix-evals` + virtual key + README loop | annotations + dataset + experiment UI |

PR 5+ (spec §10, hors scope de ce plan) : instrumentation app-level incrémentale (hermes, foreman, opencode, llmkube, memini, lightrag, headroom) — une PR par app après confirmation du support natif OTel, en s'inspirant de Task 3 comme prototype.
