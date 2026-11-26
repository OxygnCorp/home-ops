# Adoption des changements joryirving/home-ops (reste des items) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reprendre, un PR par item, les 8 changements identifiés dans le delta 2026-09-26 → 2026-11-26 de `joryirving/home-ops` qui ont un intérêt réel dans ce cluster mono-cluster (4 nœuds, 1 worker GPU tainté).

**Architecture:** Aucun refactor transverse. Chaque item est indépendant et livré dans son propre worktree/branche/PR, validé par `flate` en local et par konflate sur la PR. Les items de la phase 0 sont déjà livrés ; les phases suivantes sont ordonnées par rapport valeur/risque décroissant.

**Tech Stack:** Flux `HelmRelease`/`Kustomization`/`OCIRepository`, `bjw-s/app-template` 5.3.0, litellm-operator (`litellm.home-operations.com/v1alpha1`), kube-prometheus-stack `AlertmanagerConfig`, external-secrets (1Password), `flate` 0.8.0.

**Spec:** analyse du 2026-11-26 (delta 2 mois de `joryirving/home-ops`) ; l'analyse complète est dans le fil de discussion de la session et les PR #6109 / #6110 en sont les deux premiers livrables.

## Global Constraints

- Worktree dédié par item : `git worktree add ../home-ops-<sujet> -b <type>/<sujet>` ; ne jamais travailler dans `/home/opencode/projects/home-ops` (checkout principal).
- Ne stage que les fichiers listés dans la tâche — jamais `git add -A` ni `git add .`.
- Un item = un PR. Pas de PR fourre-tout.
- Validation avant push : `mise exec -- flate test hr --path ./kubernetes/apps/<ns>/<app>/app` (et `flate test ks --path ./kubernetes/apps` si un `ks.yaml` est touché).
- `metadata.namespace` jamais inline sur `HelmRelease`/`Kustomization` : injecté par le `kustomization.yaml` de l'app (`namespace:`).
- Images en `tag@sha256:` (digest pinné) ; les charts OCI restent pinnés par tag.
- Aucun `flux reconcile` / `just kube sync` forcé après un push : le repo est webhooké et Flux réconcilie seul (voir Task 2).
- Secrets : jamais de valeur en clair ; 1Password via `ExternalSecret`/`PushSecret`. Les clés LiteLLM sont des *properties* de l'item `litellm` (une par agent) ; les secrets propres à une app vivent sur un item dédié à son nom (ici `alert-triage`).
- Quality pass obligatoire : un subagent `reviewer` fresh-context sur le diff final avant d'ouvrir la PR.

### Phase 0 — livré

- [x] **PR #6109** `fix(descheduler): rebalance nodes with LowNodeUtilization` — `kubernetes/apps/kube-system/descheduler/app/helmrelease.yaml` : `metricsProviders`, `nodeFit`, `podProtections`, `LowNodeUtilization` 20 %/50 %.
- [x] **PR #6110** `fix(ci): allow OSV/NVD/CVE lookups in the AI PR review` — `allowed-source-hosts` (+ `api.osv.dev,osv.dev,nvd.nist.gov,www.cve.org`) sur `ai-pr-review.yaml` **et** `ai-pr-review-labels.yaml`.

---

## Phase 1 — petits gains, risque quasi nul

### Task 1: `nvidia-power-limit` (cap 300 W sur `k8s-3`)

**Files:**
- Create: `kubernetes/apps/kube-system/nvidia-power-limit/ks.yaml`
- Create: `kubernetes/apps/kube-system/nvidia-power-limit/app/kustomization.yaml`
- Create: `kubernetes/apps/kube-system/nvidia-power-limit/app/ocirepository.yaml`
- Create: `kubernetes/apps/kube-system/nvidia-power-limit/app/helmrelease.yaml`
- Modify: `kubernetes/apps/kube-system/kustomization.yaml` (ajout de `./nvidia-power-limit/ks.yaml`)

**Interfaces:**
- Consumes: RuntimeClass `nvidia` (déjà créée par `kubernetes/apps/kube-system/nvidia-device-plugin/app/runtimeclass.yaml`), taint `workload=ai:NoSchedule` sur `k8s-3`, driver NVIDIA monté par le device plugin.
- Produces: DaemonSet `nvidia-power-limit` sur `k8s-3` uniquement, GPU persistencé en mode `-pm 1` et plafonné à 300 W (`nvidia-smi -pl`).

- [ ] **Step 1: Créer `app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: nvidia-power-limit
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.3.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 2: Créer `app/helmrelease.yaml`**

`nodeSelector`/`tolerations` sont adaptés au cluster (jory cible `topology.kubernetes.io: egpu` et tolère le taint control-plane ; ici c'est `k8s-3` + `workload=ai`). Le `$${...}` est l'échappement Flux pour éviter la substitution post-build.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app nvidia-power-limit
spec:
  interval: 1h
  chartRef:
    kind: OCIRepository
    name: nvidia-power-limit
  values:
    defaultPodOptions:
      runtimeClassName: nvidia
      nodeSelector:
        kubernetes.io/hostname: k8s-3
      tolerations:
        - key: workload
          operator: Equal
          value: ai
          effect: NoSchedule
    controllers:
      nvidia-power-limit:
        type: daemonset
        containers:
          app:
            image:
              repository: docker.io/library/debian
              tag: 13-slim@sha256:8aa5a7bf5a1955bddbe7d74fcdd0b91ab30e74362a8b73af672b0481b35b44a0
            env:
              NVIDIA_VISIBLE_DEVICES: all
              NVIDIA_DRIVER_CAPABILITIES: utility
              # Défaut carte : 420 W. 300 W mesuré sans perte de débit
              # (58.0 tok/s à 330 W contre 58.8 à 300 W) sur la charge de
              # référence côté jory ; à re-mesurer ici avant de descendre plus.
              POWER_LIMIT_WATTS: "300"
            command:
              - /bin/bash
              - -c
              - |
                set -euo pipefail
                nvidia-smi -pm 1
                # Clamp : certaines cartes (ou un vGPU) exposent un
                # power.max_limit < 300 W ; sans ça `-pl` échoue et le
                # conteneur part en CrashLoop.
                MAX=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits \
                  | head -n1 | cut -d. -f1 | tr -d ' ')
                if [ "$MAX" -lt "$${POWER_LIMIT_WATTS}" ]; then
                  echo "power.max_limit=${MAX}W < POWER_LIMIT_WATTS=$${POWER_LIMIT_WATTS}W, clamping" >&2
                  POWER_LIMIT_WATTS="$MAX"
                fi
                nvidia-smi -pl "$POWER_LIMIT_WATTS"
                nvidia-smi -q -d POWER | grep -E "Power Limit|Default Power Limit|Max Power Limit"
                exec sleep infinity
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                memory: 64Mi
            securityContext:
              privileged: true
              runAsNonRoot: false
              runAsUser: 0
              runAsGroup: 0
```

- [ ] **Step 3: Créer `app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kube-system
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
```

- [ ] **Step 4: Créer `ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: nvidia-power-limit
spec:
  # La RuntimeClass `nvidia` est créée par nvidia-device-plugin : sans elle
  # les pods du DaemonSet restent en erreur (runtime handler absent).
  dependsOn:
    - name: nvidia-device-plugin
      namespace: kube-system
  commonMetadata:
    labels:
      app.kubernetes.io/name: nvidia-power-limit
  interval: 1h
  path: ./kubernetes/apps/kube-system/nvidia-power-limit/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: kube-system
  wait: false
```

- [ ] **Step 5: Enregistrer l'app** — ajouter `- ./nvidia-power-limit/ks.yaml` dans `kubernetes/apps/kube-system/kustomization.yaml`

- [ ] **Step 6: Valider**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/kube-system/nvidia-power-limit/app
mise exec -- flate test ks --path ./kubernetes/apps/kube-system
```

Expected: `✓ HelmRelease nvidia-power-limit`, aucun blocked.

- [ ] **Step 7: Commit + PR**

```bash
git add kubernetes/apps/kube-system/nvidia-power-limit kubernetes/apps/kube-system/kustomization.yaml
git commit -m "feat(nvidia-power-limit): cap the k8s-3 GPU at 300W"
```

---

### Task 2: documenter « ne pas forcer le reconcile »

**Files:**
- Modify: `AGENTS.md:61` (fast-path sécurité Renovate)
- Modify: `AGENTS.md:208` (section `Flux Debug Quickref`)

**Interfaces:** aucune (doc seule).

- [ ] **Step 1: Corriger la ligne 61**

Remplacer :

```markdown
- **Emergency security patch fast-path**: `minimumReleaseAge` only delays PR creation — it never blocks a manual merge. For a zero-day patch, edit the image directly in Git (pin the digest), merge, and `just kube sync`; don't wait on Renovate.
```

par :

```markdown
- **Emergency security patch fast-path**: `minimumReleaseAge` only delays PR creation — it never blocks a manual merge. For a zero-day patch, edit the image directly in Git (pin the digest), merge, and let the Flux webhook reconcile; don't wait on Renovate.
```

- [ ] **Step 2: Ajouter la note dans `Flux Debug Quickref`**, juste après le bloc de commandes `flux` (avant la phrase renvoyant vers `flux-debugger`) :

```markdown
**Every push to `main` is webhooked into Flux and reconciles automatically — do not force reconciles (`just kube sync`, `flux reconcile`) after pushing.** Forced reconciles defeat the webhook path, cause duplicate rollouts, and make it impossible to tell whether a change actually deployed on its own. The `just` recipes stay for *diagnosis* (a stuck resource that the webhook did not pick up), never as a reflex after a merge.
```

- [ ] **Step 3: Commit + PR** (`docs(agents): do not force reconciles after a push`)

---

## Phase 2 — alert-triage (le vrai gain d'exploitation)

But : corréler les alertes en incidents, enrichir avec l'état réel du cluster (pods unhealthy, events warning, transitions HelmRelease/Kustomization), et faire narrer le tout par LiteLLM en 2 phrases + un verdict d'actionnabilité (`git` / `partial` / `cluster` / `external`). Deux commits, un seul PR (l'app ne sert à rien sans sa route Alertmanager).

### Task 3: clé LiteLLM dédiée

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/virtualkeys/alert-triage.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/virtualkeys/kustomization.yaml`
- Action utilisateur : créer/valider l'item 1Password `alert-triage` (vault `home-ops`) avec `DISCORD_TRIAGE_WEBHOOK_URL` et `WEBHOOK_TOKEN`.

**Interfaces:**
- Consumes: pattern existant `radar.yaml` (LiteLLMVirtualKey + PushSecret vers 1Password).
- Produces: secret `litellm-key-alert-triage` (ns `ai`) **et** property `KEY_ALERT_TRIAGE` sur l'item 1Password `litellm`, consommée ensuite par l'`ExternalSecret` de l'app.

- [ ] **Step 1: Créer `alert-triage.yaml`** sur le modèle exact de `radar.yaml`

```yaml
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMVirtualKey
metadata:
  name: alert-triage
spec:
  proxyRef: litellm
  keyAlias: Alert Triage
  # Pas de team : la clé ne sert qu'à appeler /v1/chat/completions depuis
  # l'in-cluster. Même choix que radar/lightrag.
  secretName: litellm-key-alert-triage
  secretKey: api-key
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/pushsecret_v1alpha1.json
apiVersion: external-secrets.io/v1alpha1
kind: PushSecret
metadata:
  name: alert-triage
spec:
  refreshInterval: 1h
  secretStoreRefs:
    - name: onepassword
      kind: ClusterSecretStore
  selector:
    secret:
      name: litellm-key-alert-triage
  data:
    - match:
        secretKey: api-key
        remoteRef:
          remoteKey: litellm
          property: KEY_ALERT_TRIAGE
```

- [ ] **Step 2: Ajouter `./alert-triage.yaml` dans `virtualkeys/kustomization.yaml`**

- [ ] **Step 3: Valider** — `mise exec -- flate test ks --path ./kubernetes/apps/ai/litellm`

- [ ] **Step 4: Vérifier que la clé a bien été poussée dans 1Password**

Sans cette vérification, l'`ExternalSecret` de Task 4 rendra `LITELLM_API_KEY: ""` **sans aucune erreur** (l'extract réussit même si la property manque), et la panne ne sortira qu'au premier appel LiteLLM (401 silencieux).

```bash
# valeur non vide côté Kubernetes
kubectl -n ai get secret litellm-key-alert-triage -o jsonpath='{.data.api-key}' | base64 -d | wc -c
# property présente sur l'item 1Password
kubectl -n ai get pushsecret alert-triage -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
```

Expected: un nombre > 0, et une condition `Ready` sans erreur.

- [ ] **Step 5: Commit** (`feat(litellm): add alert-triage virtual key`)

### Task 4: app `alert-triage` dans `observability`

**Files:**
- Create: `kubernetes/apps/observability/alert-triage/ks.yaml`
- Create: `kubernetes/apps/observability/alert-triage/app/kustomization.yaml`
- Create: `kubernetes/apps/observability/alert-triage/app/ocirepository.yaml`
- Create: `kubernetes/apps/observability/alert-triage/app/externalsecret.yaml`
- Create: `kubernetes/apps/observability/alert-triage/app/pvc.yaml`
- Create: `kubernetes/apps/observability/alert-triage/app/helmrelease.yaml`
- Modify: `kubernetes/apps/observability/kustomization.yaml`

**Interfaces:**
- Consumes: `litellm` service `http://litellm.ai:4000/v1`, secret `alert-triage` (produit par **Step 2**, `externalsecret.yaml`) et `litellm-key-alert-triage` (Task 3).
- Produces: `Service alert-triage:8080/webhook` + `/healthz`, `ClusterRole alert-triage` en lecture seule (nodes, pods, pods/log, events, jobs, helmreleases, helmcharts, kustomizations, sources Flux).

- [ ] **Step 1: `app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: alert-triage
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 5.3.0
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

- [ ] **Step 2: `app/externalsecret.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: &name alert-triage
spec:
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: *name
    template:
      engineVersion: v2
      data:
        DISCORD_WEBHOOK_URL: "{{ .DISCORD_TRIAGE_WEBHOOK_URL }}"
        WEBHOOK_TOKEN: "{{ .WEBHOOK_TOKEN }}"
        LITELLM_API_KEY: "{{ .KEY_ALERT_TRIAGE }}"
  dataFrom:
    - extract:
        key: alert-triage
    - extract:
        key: litellm
```

- [ ] **Step 3: `app/pvc.yaml`** — 1 Gi sur `miroir-slow-local` (l'historique JSONL n'est pas une donnée précieuse : pas de réplication DRBD, l'app applique elle-même `RETENTION=168h`).

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/v1/persistentvolumeclaim_v1.json
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: alert-triage
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: miroir-slow-local
  resources:
    requests:
      storage: 1Gi
```

- [ ] **Step 4: `app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: alert-triage
spec:
  interval: 15m
  chartRef:
    kind: OCIRepository
    name: alert-triage
  dependsOn:
    - name: kube-prometheus-stack
      namespace: observability
  values:
    defaultPodOptions:
      # L'app lit pods, events et état Flux via l'API in-cluster ; app-template
      # désactive le token par défaut, il faut le réactiver explicitement.
      automountServiceAccountToken: true
      securityContext:
        runAsNonRoot: true
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
        fsGroupChangePolicy: OnRootMismatch
    controllers:
      alert-triage:
        annotations:
          reloader.stakater.com/auto: "true"
        strategy: Recreate
        serviceAccount:
          identifier: alert-triage
        containers:
          app:
            image:
              repository: ghcr.io/misospace/alert-triage
              tag: 0.3.0@sha256:fe3e6b6ae6a23aa9449f1d8d0f48330dcd387a85629c286bf0365d1b5b9c8822
            env:
              # `CLUSTER` matche le label `cluster` des alertes. Ce cluster
              # n'a pas d'`externalLabels.cluster` sur kube-prometheus-stack :
              # avec `CLUSTER: main` aucun groupe ne serait reconnu, donc
              # l'enrichissement serait systématiquement vide (sans erreur).
              # Laisser vide = enrichit tous les groupes. Si un jour
              # `externalLabels.cluster: main` est ajouté, remettre `main`.
              LITELLM_URL: http://litellm.ai:4000/v1
              MODEL: dsv41f
              HISTORY_PATH: /data/history.jsonl
              METRICS_URL: http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
            envFrom:
              - secretRef:
                  name: "{{ .Release.Name }}"
            probes:
              liveness: &probe
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /healthz
                    port: 8080
                  initialDelaySeconds: 5
                  periodSeconds: 30
              readiness: *probe
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities: { drop: ["ALL"] }
            resources:
              requests:
                cpu: 10m
                memory: 32Mi
              limits:
                memory: 128Mi
    serviceAccount:
      alert-triage: {}
    rbac:
      roles:
        alert-triage:
          type: ClusterRole
          rules:
            - apiGroups: [""]
              resources: ["pods", "events", "nodes"]
              verbs: ["get", "list"]
            - apiGroups: [""]
              resources: ["pods/log"]
              verbs: ["get"]
            # Résolution des alertes `KubeJobFailed` (l'alerte nomme le Job,
            # pas le pod : sans ça le pod en échec n'apparaît pas).
            - apiGroups: ["batch"]
              resources: ["jobs"]
              verbs: ["get", "list"]
            - apiGroups: ["helm.toolkit.fluxcd.io"]
              resources: ["helmreleases"]
              verbs: ["get", "list"]
            # `HelmChart` est resté dans le groupe helm (servi en v2beta1)
            # même après le passage du kind dans le groupe source.
            - apiGroups: ["helm.toolkit.fluxcd.io"]
              resources: ["helmcharts"]
              verbs: ["get"]
            - apiGroups: ["kustomize.toolkit.fluxcd.io"]
              resources: ["kustomizations"]
              verbs: ["get", "list"]
            # Déréférencement des `sourceRef` : c'est ce qui alimente le
            # verdict `git` / `partial`. Sans ces règles, l'enrichissement
            # se dégrade en silence ("not checked"), pas en 403.
            - apiGroups: ["source.toolkit.fluxcd.io"]
              resources: ["gitrepositories", "ocirepositories", "buckets", "helmcharts"]
              verbs: ["get"]
      bindings:
        alert-triage:
          type: ClusterRoleBinding
          roleRef:
            identifier: alert-triage
          subjects:
            - identifier: alert-triage
              serviceAccount: alert-triage
    service:
      app:
        controller: alert-triage
        annotations:
          gatus.home-operations.com/endpoint: |-
            group: services
            url: http://alert-triage.observability.svc.cluster.local:8080/healthz
            conditions: ["[STATUS] == 200"]
        ports:
          http:
            port: 8080
    persistence:
      data:
        existingClaim: "{{ .Release.Name }}"
        globalMounts:
          - path: /data
```

- [ ] **Step 5: `app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.config.k8s.io/kustomization_v1beta1.json
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: observability
resources:
  - ./ocirepository.yaml
  - ./externalsecret.yaml
  - ./pvc.yaml
  - ./helmrelease.yaml
```

- [ ] **Step 6: `ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: alert-triage
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: alert-triage
  dependsOn:
    - name: kube-prometheus-stack
      namespace: observability
    - name: litellm
      namespace: ai
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: alert-triage
      namespace: observability
  interval: 1h
  path: ./kubernetes/apps/observability/alert-triage/app
  prune: true
  retryInterval: 2m
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: observability
  wait: true
```

- [ ] **Step 7: Enregistrer l'app** — ajouter `- ./alert-triage/ks.yaml` dans `kubernetes/apps/observability/kustomization.yaml`

- [ ] **Step 8: Valider**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/observability/alert-triage/app
mise exec -- flate test ks --path ./kubernetes/apps/observability
```

Expected: `✓ HelmRelease alert-triage`. Si flate signale le secret `alert-triage` manquant, c'est le même warning bénin que `cloudflare-tunnel` (ExternalSecret pas encore synchronisé) — vérifier que l'item 1Password existe.

- [ ] **Step 9: Vérifier que le secret rendu n'est pas vide**

ESO ne signale pas une property absente : `extract` réussit et le template rend une chaîne vide.

```bash
kubectl -n observability get secret alert-triage \
  -o jsonpath='{.data.LITELLM_API_KEY}' | base64 -d | wc -c
kubectl -n observability get secret alert-triage \
  -o jsonpath='{.data.WEBHOOK_TOKEN}' | base64 -d | wc -c
```

Expected: deux valeurs > 0. Sinon, revenir à Task 3 Step 4 (PushSecret pas encore réconcilié).

- [ ] **Step 10: Commit** (`feat(observability): add alert-triage`)

> Hors scope volontaire : la `NetworkPolicy` recommandée par l'amont (n'admettre que l'Alertmanager sur le port 8080). Le token partagé couvre l'authentification ; la policy reste à ajouter si le besoin de cloisonnement réseau se présente, en cohérence avec le reste du cluster qui n'en pose pas sur les apps.

### Task 5: brancher Alertmanager

**Files:**
- Modify: `kubernetes/apps/observability/kube-prometheus-stack/app/alertmanagerconfig.yaml`

**Interfaces:**
- Consumes: `Service alert-triage:8080/webhook`, secret `alert-triage` (clé `WEBHOOK_TOKEN`).
- Produces: route `triage` en `continue: true` → les alertes partent à la fois au triage LLM et à Discord (comportement inchangé côté Discord).

- [ ] **Step 1: Insérer la route** dans `spec.route.routes`, **après** les routes `InfoInhibitor` et `Watchdog` (qui sortent du parcours : ces deux alertes ne doivent jamais être triées) et **avant** la route `severity: critical` :

Périmètre volontairement large au départ (toute alerte qui arrive là part au triage, comme chez jory) : c'est le seul moyen d'évaluer la qualité des corrélations sur le trafic réel. Le levier de réduction, si le volume ou le coût gêne, est l'opt-in par label recommandé par l'amont — dans cet ordre : 1) déployer sans `TRIAGE_LABEL`, 2) poser `triage: "true"` sur les PrometheusRules utiles, 3) ajouter `matchLabels: {triage: "true"}` sur la route, 4) poser `TRIAGE_LABEL: triage` sur l'app (le webhook re-filtre en filet de sécurité).

```yaml
      # Triage LLM : corrèle et enrichit les alertes, puis poste un embed
      # Discord avec un verdict d'actionnabilité. continue: true pour ne pas
      # intercepter les routes existantes.
      - receiver: triage
        continue: true
        groupWait: 0s
        groupInterval: 1m
        repeatInterval: 12h
```

- [ ] **Step 2: Ajouter le receiver** en tête de `spec.receivers` :

```yaml
    - name: triage
      webhookConfigs:
        - url: http://alert-triage.observability.svc.cluster.local:8080/webhook
          sendResolved: false
          httpConfig:
            authorization:
              credentials:
                name: alert-triage
                key: WEBHOOK_TOKEN
```

- [ ] **Step 3: Valider** — `mise exec -- flate test hr --path ./kubernetes/apps/observability/kube-prometheus-stack/app`

- [ ] **Step 4: Commit + PR** (`feat(observability): route alerts through alert-triage`) et quality pass `reviewer` sur l'ensemble du diff Phase 2.

**Critère de succès :** à la prochaine alerte réelle (ou une alerte de test injectée via `amtool`/un pod qui crash-loop), un embed Discord arrive avec la narration LLM **et** l'enrichissement (pods/events/Flux) n'est pas vide ; `kubectl -n observability logs deploy/alert-triage` ne montre ni 401 LiteLLM ni erreur de lecture API. Contrôle complémentaire : `curl -s -H "Authorization: Bearer $WEBHOOK_TOKEN" localhost:8080/recent | jq '.[0].evidence'` (via port-forward) montre bien `unhealthyPods`/`warningEvents`/Flux renseignés — un RBAC incomplet dégrade en silence ("not checked"), il ne produit pas de 403.

---

## Phase 3 — durcissement du reviewer (décision requise)

### Task 6: paramètres `pr-reviewer-action` *(à valider ensemble)*

**Files:** `.github/workflows/ai-pr-review.yaml`, `.github/workflows/ai-pr-review-labels.yaml`

Paramètres de jory absents ici, du moins risqué au plus structurant :

| Paramètre | Effet | Risque |
|---|---|---|
| `claim-falsification: "true"` | le reviewer doit *réfuter* ses propres affirmations avant de conclure | aucun, gain de précision |
| `review-verbosity: concise` | moins de bruit dans les commentaires | aucun |
| `ai-extra-headers: x-litellm-session-id: prreview-<run>` | affinité LiteLLM → cache + attribution de coût par run | aucun |
| `repository-skills: "true"` + `.agents/skills/renovate-review/SKILL.md` | standards de review chargés à la demande au lieu du prompt système permanent | moyen : déplace du contenu hors de `pr-review.instructions.md` |
| `publish-mode: review_verdict` | supprime le job `automerge-gate` maison (~350 lignes) | **élevé** : change la logique de blocage |

Décision à prendre : ne faire que la première colonne (sûr), ou évaluer aussi la sortie du gate maison. Le gate actuel est plus fin mais c'est la source des incidents `cancelled`/`skipped` documentés dans `AGENTS.md`.

## Phase 4 — pools LiteLLM (décision de design)

### Task 7: alias logiques de modèles *(à valider ensemble)*

Constat : les `modelName` actuels sont déjà des groupes à plusieurs rangs (`dsv41f` + `dsv41f-agnes`, `go-glm-5.3` + `go-glm-5.3-agnes`), et les coûts sont bien remontés à LiteLLM via `params.additional.*_cost_per_token`. Il ne manque que la **couche d'alias** : des noms de pool (`coding-pool`, `reasoning-pool`) découplés du modèle sous-jacent, pour changer de provider sans toucher 30 fichiers de virtualkeys.

Décision requise : les noms de pools, et quels virtualkeys y sont rattachés (`pr-review`, `radar`, `memini`, `mainclaw-*`…). Sans cette décision, ne rien écrire.

## Phase 5 — optionnel / différé

### Task 8: Flux `source-watcher` — **différé**

Prérequis des artefacts par app (`ArtifactGenerator`/`ExternalArtifact`). Aucun bénéfice aujourd'hui, et l'activation fait redémarrer kustomize-controller et helm-controller. Le diff, si un jour nécessaire :

```diff
       components:
         - source-controller
         - kustomize-controller
         - helm-controller
         - notification-controller
+        - source-watcher
```

plus `- source-watcher` dans `kubernetes/apps/flux-system/flux-instance/app/podmonitor.yaml`.

### Task 9: OpenTofu (`terraform/{uptimerobot,authentik,onepassword}`) — **reporté**

Le pattern `terraform-diff.yaml` (commentaire de diff sur PR) est bon, mais suppose un état distant et une org GitHub dédiée. À reprendre si le besoin d'infra-as-code hors cluster apparaît.

### Non repris

Dispatch/Courier (boucle issue→PR autonome), LLMKube/OVMS-NPU/`llm-wake`, paseo/openclaw/hermes, refactor multi-cluster `base/` + overlays, `components/namespace`, `tag.yaml`/model-catalogs.
