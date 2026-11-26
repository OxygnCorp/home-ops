# Adoptions onedr0p/home-ops — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adopter, chantier par chantier, les changements intéressants repérés dans `onedr0p/home-ops` entre le 2026-10-26 et le 2026-11-26, sans casser le cluster.

**Architecture:** Chaque chantier est indépendant : une branche, un worktree, une PR, une validation `flate`, un rollback documenté. Les chantiers sont ordonnés du moins risqué au plus risqué. Le point 1 (OCIRepository 15m→1h) est déjà fait.

**Tech Stack:** Talos 1.14.7 / Kubernetes 1.37.3, Flux (flux-operator), HelmRelease + OCIRepository, Cilium, Envoy Gateway, kube-prometheus-stack 93.11.0 + prompp, kopiur 0.11.2, Miroir 0.12.13, VictoriaLogs.

**Spec:** Analyse du 2026-11-26 (291 commits onedr0p, PRs #12089 à #12266). Ce document remplace le rapport oral : chaque chantier cite la PR upstream et l'écart exact avec le cluster.

## Global Constraints

- **Isolation Git** : un worktree dédié et une branche par chantier (`git worktree add ../home-ops-<sujet> -b <type>/<sujet>`). Ne jamais travailler dans le checkout principal.
- **Staging** : ne stage que les fichiers créés/modifiés pour le chantier. Jamais `git add -A` ni `git add .`.
- **Validation obligatoire avant PR** (exit code 0 exigé) :
  ```bash
  # Le Secret cloudflare-tunnel est créé à l'exécution par external-secrets :
  # flate ne peut pas le rendre, on lui fournit un document factice.
  cat > /tmp/flate-supply.yaml <<'EOF'
  apiVersion: v1
  kind: Secret
  metadata:
    name: cloudflare-tunnel-id-secret
    namespace: network
  type: Opaque
  stringData:
    CLOUDFLARE_TUNNEL_ID: ci
  EOF
  mise exec -- flate test ks --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
  mise exec -- flate test hr --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
  ```
  Sans `--supply`, les deux commandes sortent en **exit 1** à cause de ce seul blocage pré-existant (vérifié). Les warnings `StaleValues` (dragonfly-operator, envoy-gateway) sont pré-existants et n'échouent pas.
- **Pas de kubeconfig dans le shell de l'agent** : les vérifications post-merge passent par les MCP `radar` / `grafana`, ou par l'utilisateur (`kubectl` depuis son poste).
- **Versions de référence** : Kubernetes `v1.37.3`, Talos `v1.14.7`, flate `0.8.0`, kopiur `0.11.2`, Miroir `0.12.13`, kube-prometheus-stack `93.11.0`, fluent-bit `0.58.3`.
- **Faits upstream vérifiés** :
  - `HPAScaleToZero` est **beta et activé par défaut depuis Kubernetes 1.37** → rien à activer sur ce cluster (1.37.3).
  - `CrossNamespaceVolumeDataSource` est **toujours alpha** en 1.37 (table upstream) → gate requis sur apiserver, controller-manager et csi-provisioner.
- **Merge** : PR + revue, squash merge (convention du repo).

---

## État initial

| Point | Statut |
|---|---|
| 1. OCIRepository `15m` → `1h` | ✅ **Fait** — PR [#6108](https://github.com/OxygnCorp/home-ops/pull/6108), 79 fichiers + template `add-app`; `ai/opencode` reste à `5m` ; revue `reviewer` APPROVE. |
| 2. Kube-apiserver histogram drops | ✅ **Déjà couvert** — voir « Déjà couvert » ci-dessous, aucun changement requis. |
| 3 à 10 | À traiter ci-dessous. |
| 11. StatefulSet claim templates | ❌ Non retenu (voir « Non retenus »). |

---

## Chantier 3 — Hubble : labels bornés + buffer

**PR upstream :** #12242, #12244, #12245 — **Effort :** 15 min — **Risque :** faible.

**Pourquoi :** les labels Hubble par défaut (`source`, `destination`, `identity`) explosent la cardinalité Prometheus. On les remplace par les namespaces + le contexte applicatif borné, et on augmente le buffer d'événements (le flux est plus riche mais moins de séries).

**Files:**
- Modify: `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml:38-58`

**Interfaces:**
- Consomme : le chart Cilium et ses values `hubble.*`.
- Produit : aucune dépendance pour les autres chantiers.

- [ ] **Étape 1 : appliquer le bloc cible**

Remplacer le bloc `hubble:` actuel par (on conserve `relay.prometheus` et `ui.standalone` propres au cluster) :

```yaml
    hubble:
      enabled: true
      eventBufferCapacity: "65535"
      metrics:
        enabled:
          - dns:query;response
          - drop:labelsContext=source_namespace,destination_namespace;sourceContext=app|reserved-identity;destinationContext=app|reserved-identity
          - flow:labelsContext=source_namespace,destination_namespace;sourceContext=app|reserved-identity;destinationContext=app|reserved-identity
          - icmp:labelsContext=source_namespace,destination_namespace;sourceContext=app|reserved-identity;destinationContext=app|reserved-identity
          - tcp:labelsContext=source_namespace,destination_namespace;sourceContext=app|reserved-identity;destinationContext=app|reserved-identity
        serviceMonitor:
          enabled: true
      relay:
        enabled: true
        prometheus:
          enabled: true
          serviceMonitor:
            enabled: true
      ui:
        enabled: true
        standalone:
          enabled: true
```

Notes :
- `port-distribution` reste supprimé (déjà commenté, ~99k séries).
- On garde `dns:query;response` (contrairement à onedr0p) : les dashboards DNS du cluster s'appuient dessus. Si personne ne les consulte, retirer cette ligne dans un second temps.
- `icmp` est ajouté comme upstream ; il apporte peu de séries avec des labels bornés.

- [ ] **Étape 2 : valider**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/kube-system/cilium
```
Attendu : `✓` et exit 0.

- [ ] **Étape 3 : commit + PR**

```bash
git add kubernetes/apps/kube-system/cilium/app/helmrelease.yaml
git commit -m "chore(cilium): bound hubble metric labels and raise event buffer"
```

**Post-merge :** `kubectl -n kube-system rollout status ds/cilium` puis vérifier dans Grafana que `hubble_flows_processed_total` garde des labels `source_namespace`/`destination_namespace` et que la cardinalité baisse.

**Rollback :** `git revert` de la PR (les anciennes séries réapparaissent au scrape suivant).

---

## Chantier 4 — Envoy : supprimer les NodePorts du Service LB

**PR upstream :** #12169 — **Effort :** 5 min — **Risque :** faible (mais vérifier qu'aucun accès ne dépend des NodePorts).

**Pourquoi :** les Gateways sont exposées par Cilium LB-IPAM (VIPs `10.10.98.250/.251`) et BGP, pas par les nœuds. Les NodePorts alloués par le Service `LoadBalancer` sont inutiles et élargissent la surface.

**Files:**
- Modify: `kubernetes/apps/network/envoy-gateway/app/envoy.yaml` (bloc `spec.provider.kubernetes.envoyService`)

**Interfaces:**
- Consomme : l'EnvoyProxy existant (`envoy-external` / `envoy-internal`).
- Produit : aucun.

- [ ] **Étape 1 : ajouter le champ**

```yaml
      envoyService:
        externalTrafficPolicy: Local
        allocateLoadBalancerNodePorts: false
```

- [ ] **Étape 2 : vérifier qu'aucun usage NodePort n'existe**

```bash
git grep -n "nodePort" kubernetes/ || true
```
Attendu : aucune référence à un NodePort des Services Envoy. Si une sonde externe vise `<node-ip>:<nodeport>`, elle doit être basculée sur la VIP avant merge.

- [ ] **Étape 3 : valider**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/network/envoy-gateway
```

- [ ] **Étape 4 : commit + PR**

```bash
git add kubernetes/apps/network/envoy-gateway/app/envoy.yaml
git commit -m "chore(envoy): drop unused LoadBalancer node ports"
```

**Post-merge :** `kubectl -n network get svc envoy-external envoy-internal -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.allocateLoadBalancerNodePorts}{"\n"}{end}'` → `false false`; vérifier que `https://<un hostname public>` répond toujours.

**Rollback :** retirer la ligne (Flux réalloue des NodePorts au reconcile suivant).

---

## Chantier 5 — CI : valider les manifestes avec flate sur chaque PR

**PR upstream :** #12188 — **Effort :** 20 min — **Risque :** faible.

**Pourquoi :** aujourd'hui `flate` n'est lancé qu'en local. Une PR qui casse un `HelmRelease` ou une référence de chart n'est détectée qu'après merge par Flux. Le job bloque la PR avant merge.

**Files:**
- Create: `.github/workflows/flate.yaml`

**Interfaces:**
- Consomme : `.mise/config.toml` (flate 0.8.0), le Secret runtime `cloudflare-tunnel-id-secret`.
- Produit : un check requis (à activer dans la protection de branche après le premier run vert).

- [ ] **Étape 1 : créer le workflow**

```yaml
---
name: Flate
on:
  pull_request:
    branches:
      - main
concurrency:
  group: ${{ github.workflow }}-${{ github.event.number || github.ref }}
  cancel-in-progress: true
permissions:
  contents: read
jobs:
  validate:
    name: Flate - Validate
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          persist-credentials: false
      - name: Setup Mise
        uses: jdx/mise-action@924e7c586e33d7d4bae9c14e26c5d22e2beb6e78 # v5.3.0
        with:
          version: v2026.11.14
      # external-secrets crée ce Secret à l'exécution ; flate exige un document
      # lisible pour rendre la Kustomization cloudflare-tunnel. Valeurs factices.
      - name: Supply runtime-only secrets
        run: |
          cat > "${RUNNER_TEMP}/flate-supply.yaml" <<'EOF'
          apiVersion: v1
          kind: Secret
          metadata:
            name: cloudflare-tunnel-id-secret
            namespace: network
          type: Opaque
          stringData:
            CLOUDFLARE_TUNNEL_ID: ci
          EOF
      - name: Test Kustomizations
        run: mise exec -- flate test ks --path ./kubernetes/apps --supply "${RUNNER_TEMP}/flate-supply.yaml"
      - name: Test HelmReleases
        run: mise exec -- flate test hr --path ./kubernetes/apps --supply "${RUNNER_TEMP}/flate-supply.yaml"
```

- [ ] **Étape 2 : valider localement la commande exacte**

```bash
mise exec -- flate test ks --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
mise exec -- flate test hr --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
```
Attendu : `✓ 104 passed` et `✓ 82 passed`, exit 0 (mesuré).

- [ ] **Étape 3 : commit + PR, puis activer le check**

```bash
git add .github/workflows/flate.yaml
git commit -m "ci: validate Flux manifests with flate on pull requests"
```
Après le premier run vert, ajouter `Flate - Validate` aux checks requis de la branche `main`.

**Post-merge :** ouvrir une PR de test (par ex. ce plan) et vérifier que le job s'exécute et échoue volontairement sur une erreur de chart.

**Rollback :** supprimer le workflow (aucun impact cluster).

---

## Chantier 6 — Reloader : stratégie `annotations`

**PR upstream :** #12266 — **Effort :** 5 min — **Risque :** faible.

**Pourquoi :** la stratégie `env` par défaut déclenche des rollouts sur des changements d'environnement qui ne nécessitent pas de redémarrage. `annotations` ne réagit qu'aux annotations de reload explicites (`reloader.stakater.com/auto`, etc.), ce qui rend les redémarrages prévisibles.

**Files:**
- Modify: `kubernetes/apps/kube-system/reloader/app/helmrelease.yaml` (sous `values.reloader`)

**Interfaces:**
- Consomme : les annotations `reloader.stakater.com/*` posées sur les workloads.
- Produit : aucun.

- [ ] **Étape 1 : ajouter la valeur**

```yaml
    reloader:
      enableHA: true
      reloadStrategy: annotations
      deployment:
        replicas: 2
```

- [ ] **Étape 2 : vérifier les workloads qui comptent sur la stratégie implicite**

```bash
git grep -rn "reloader.stakater.com" kubernetes/ | head -50
```
Les annotations explicites (`auto`, `search`, `match`) continuent de fonctionner. Si un workload comptait sur le reload automatique par variable d'environnement (sans annotation), il faudra l'annoter.

- [ ] **Étape 3 : valider + commit + PR**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/kube-system/reloader
git add kubernetes/apps/kube-system/reloader/app/helmrelease.yaml
git commit -m "chore(reloader): use annotations reload strategy"
```

**Post-merge :** `kubectl -n kube-system get deploy reloader -o jsonpath='{.spec.template.spec.containers[0].args}'` doit contenir `--reload-strategy=annotations`.

**Rollback :** retirer la ligne.

---

## Chantier 7 — Rétention Prometheus : 90 j (sous condition de disque)

**PR upstream :** #12253 (onedr0p : 120 j) — **Effort :** 15 min + vérification — **Risque :** moyen (PVC / DRBD).

**Pourquoi :** 30 j est court pour les tendances capacity planning. Mais `retentionSize: 40GB` plafonne déjà la rétention réelle, et le PVC fait 50Gi : augmenter `retention` sans augmenter `retentionSize` + PVC ne changera rien.

**Files:**
- Modify: `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` (`spec.values.prometheus.prometheusSpec`)

**Interfaces:**
- Consomme : la StorageClass `miroir-slow` (expansion).
- Produit : aucun.

- [ ] **Étape 1 : mesurer l'usage réel (MCP grafana ou poste utilisateur)**

```promql
prometheus_tsdb_storage_blocks_bytes
kubelet_volume_stats_used_bytes{persistentvolumeclaim=~"prometheus-kube-prometheus-stack-db-.*"}
```
Calculer la croissance quotidienne = usage / 30. Décider :
- croissance × 90 ≤ **32 GiB** → cible `retention: 90d`, `retentionSize: 40GB`, PVC **60Gi**.
- croissance × 90 > 32 GiB → rester à 30 j (le gain ne vaut pas un PVC > 80Gi sur DRBD).

- [ ] **Étape 2 : vérifier l'expansion de la StorageClass**

```bash
kubectl get sc miroir-slow -o jsonpath='{.allowVolumeExpansion}'
```
Attendu : `true`. Si `false`, **ne pas toucher au PVC** : garder 50Gi et 30 j.

- [ ] **Étape 3 : appliquer**

```yaml
        retention: 90d
        retentionSize: 40GB
        storageSpec:
          volumeClaimTemplate:
            spec:
              storageClassName: miroir-slow
              resources:
                requests:
                  storage: 60Gi
```

- [ ] **Étape 4 : valider + commit + PR**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/observability/kube-prometheus-stack
git add kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml
git commit -m "chore(prometheus): retain metrics for 90 days"
```

**Post-merge :** vérifier `kubectl -n observability get pvc -l app.kubernetes.io/name=prometheus` → `60Gi`, et dans Prometheus `--storage.tsdb.retention.time=90d`. Surveiller l'usage DRBD 48 h.

**Rollback :** remettre `30d` / `50Gi` (le shrink PVC n'est pas supporté : recréer le PVC = perte d'historique, à éviter).

---

## Chantier 8 — Corriger la doc `zeroscaler` (HPAScaleToZero)

**PR upstream :** #12192 — **Effort :** 5 min — **Risque :** nul.

**Pourquoi :** le README affirme que le gate `HPAScaleToZero=true` est dans la config Talos. C'est faux : aucun `HPAScaleToZero` n'existe dans `talos/` (grep). Le cluster tourne en **Kubernetes 1.37.3**, où le gate est **beta et activé par défaut**. La doc doit décrire la réalité.

**Files:**
- Modify: `kubernetes/components/zeroscaler/README.md:10`

**Interfaces:**
- Consomme : rien.
- Produit : rien.

- [ ] **Étape 1 : remplacer la ligne**

Ancienne ligne :

```markdown
- HPAScaleToZero is enabled cluster-wide (see the `HPAScaleToZero=true` feature gate in the Talos control-plane config).
```

Nouvelle ligne :

```markdown
- `HPAScaleToZero` is beta and enabled by default since Kubernetes 1.37 (this cluster runs v1.37.3); no Talos feature gate is needed. Scale-to-zero requires an `External` or `Object` metric, which is why the HPA below uses `External`.
```

- [ ] **Étape 2 : vérifier la cohérence**

```bash
git grep -n "HPAScaleToZero" .
```
Attendu : une seule occurrence, dans le README corrigé.

- [ ] **Étape 3 : commit + PR**

```bash
git add kubernetes/components/zeroscaler/README.md
git commit -m "docs(zeroscaler): correct the HPAScaleToZero claim"
```

**Rollback :** aucun besoin.

---

## Chantier 9 — Logs Talos → VictoriaLogs (relay fluent-bit)

**PRs upstream :** #12173, #12174, #12176 — **Effort :** ~1 h + rollout — **Risque :** moyen (config machine Talos, volume de logs).

**Pourquoi :** VictoriaLogs ne reçoit aujourd'hui que les logs des conteneurs. Les logs kernel/kubelet/etcd/services des nœuds Talos ne sont collectés nulle part. onedr0p les pousse via un petit DaemonSet fluent-bit qui écoute en TCP et écrit dans VictoriaLogs.

**Architecture :** Talos envoie ses logs en `json_lines` vers `tcp://<ClusterIP>:6050/`. Le DaemonSet (un pod par nœud, `internalTrafficPolicy: Local`) tamponne sur un hostPath, filtre le bruit, puis pousse en HTTP vers `victoria-logs.observability.svc.cluster.local:9428`. L'IP est en dur côté Talos car le namespace hôte ne résout pas le DNS du cluster.

**Files:**
- Create: `kubernetes/apps/observability/talos-logs-relay/ks.yaml`
- Create: `kubernetes/apps/observability/talos-logs-relay/app/kustomization.yaml`
- Create: `kubernetes/apps/observability/talos-logs-relay/app/ocirepository.yaml`
- Create: `kubernetes/apps/observability/talos-logs-relay/app/helmrelease.yaml`
- Modify: `kubernetes/apps/observability/kustomization.yaml` (ajouter `- ./talos-logs-relay/ks.yaml`)
- Modify: `talos/main/cluster.yaml.j2` (ajouter `machine.logging`)

**Interfaces:**
- Consomme : `victoria-logs.observability.svc.cluster.local:9428` (vérifié dans `kubernetes/apps/observability/victoria-logs/collector/helmrelease.yaml`).
- Produit : streams VictoriaLogs `node`, `talos-service`, `facility`.

- [ ] **Étape 1 : choisir une ClusterIP libre**

```bash
kubectl get svc -A -o jsonpath='{range .items[*]}{.spec.clusterIP}{"\n"}{end}' | sort -V | grep '^10\.43\.' | tail -5
kubectl get svc -A | grep 10.43.0.60 || echo "10.43.0.60 libre"
```
Le CIDR des Services est `10.43.0.0/16` (`talos/main/cluster.yaml.j2:115`). Utiliser `10.43.0.60` s'il est libre ; sinon prendre une IP haute libre (ex. `10.43.250.60`). **La même IP doit être répétée dans le Service et dans la config Talos.**

- [ ] **Étape 2 : créer le `ks.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: talos-logs-relay
spec:
  interval: 1h
  path: ./kubernetes/apps/observability/talos-logs-relay/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: observability
  wait: false
```

- [ ] **Étape 3 : créer `app/kustomization.yaml`**

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
```

- [ ] **Étape 4 : créer `app/ocirepository.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: talos-logs-relay
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.58.3
  url: oci://ghcr.io/fluent/helm-charts/fluent-bit
```

- [ ] **Étape 5 : créer `app/helmrelease.yaml`**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: &app talos-logs-relay
spec:
  chartRef:
    kind: OCIRepository
    name: talos-logs-relay
  interval: 1h
  values:
    fullnameOverride: *app
    serviceAccount:
      create: false
      automountServiceAccountToken: false
    rbac:
      create: false
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    resources:
      requests:
        cpu: 10m
        memory: 32Mi
      limits:
        memory: 128Mi
    # k8s-3 est tainté workload=ai:NoSchedule : sans cette tolérance, aucun
    # relay n'y tourne et les logs de ce nœud sont perdus (le Service est
    # internalTrafficPolicy: Local).
    tolerations:
      - key: workload
        operator: Equal
        value: ai
        effect: NoSchedule
    env:
      - name: NODE_NAME
        valueFrom:
          fieldRef:
            fieldPath: spec.nodeName
    extraPorts:
      - name: talos
        port: 6050
        containerPort: 6050
        protocol: TCP
    # talos/main/cluster.yaml.j2 répète cette IP : le namespace hôte ne résout
    # pas le DNS du cluster. Le pod tamponne son propre node name, donc chaque
    # nœud doit joindre son pod local.
    service:
      clusterIP: 10.43.0.60
      internalTrafficPolicy: Local
    serviceMonitor:
      enabled: true
    daemonSetVolumes:
      - name: data
        hostPath:
          path: /var/lib/talos-logs-relay
          type: DirectoryOrCreate
    daemonSetVolumeMounts:
      - name: data
        mountPath: /var/lib/talos-logs-relay
    luaScripts:
      strip_newline.lua: |
        function strip_newline(tag, ts, record)
          local m = record["msg"]
          if type(m) == "string" and m:sub(-1) == "\n" then
            record["msg"] = m:sub(1, -2)
            return 2, ts, record
          end
          return 0, ts, record
        end
    config:
      service: |
        [SERVICE]
            Flush 5
            HTTP_Server On
            storage.path /var/lib/talos-logs-relay
            storage.max_chunks_up 16
            storage.backlog.mem_limit 16M
            scheduler.cap 30
      inputs: |
        [INPUT]
            Name tcp
            Alias talos
            Tag talos
            Port 6050
            Buffer_Size 256
            Chunk_Size 64
            storage.type filesystem
      filters: |
        [FILTER]
            Name grep
            Match talos
            Exclude $talos-service ^(kernel|dns-resolve-cache)$

        [FILTER]
            Name grep
            Match talos
            Logical_Op and
            Exclude $talos-service ^machined$
            Exclude $msg match\swith\sservice\s"dashboard"

        [FILTER]
            Name lua
            Match talos
            script /fluent-bit/scripts/strip_newline.lua
            call strip_newline

        [FILTER]
            Name modify
            Match talos
            Hard_rename talos-level level
            Set node ${NODE_NAME}
      outputs: |
        [OUTPUT]
            Name http
            Alias victorialogs
            Match talos
            Host victoria-logs.observability.svc.cluster.local
            Port 9428
            URI /insert/jsonline?_msg_field=msg,content&_time_field=talos-time&_stream_fields=node,talos-service,facility
            Format json_lines
            Json_date_key false
            Retry_Limit no_limits
            storage.total_limit_size 256M
```

- [ ] **Étape 6 : enregistrer l'app dans le namespace**

Dans `kubernetes/apps/observability/kustomization.yaml`, ajouter sous `resources:` (ordre alphabétique) :

```yaml
  - ./talos-logs-relay/ks.yaml
```

- [ ] **Étape 7 : déclarer la destination côté Talos**

Dans `talos/main/cluster.yaml.j2`, sous `machine:` (au même niveau que `features:`, `files:`…), ajouter :

```yaml
  logging:
    destinations:
      - endpoint: tcp://10.43.0.60:6050/
        format: json_lines
```

Remplacer `10.43.0.60` par l'IP retenue à l'étape 1 (identique au Service).

- [ ] **Étape 8 : valider le rendu**

```bash
mise exec -- flate test ks --path ./kubernetes/apps/observability/talos-logs-relay --supply /tmp/flate-supply.yaml
mise exec -- flate test hr --path ./kubernetes/apps/observability/talos-logs-relay
mise exec -- flate test ks --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
mise exec -- flate test hr --path ./kubernetes/apps --supply /tmp/flate-supply.yaml
just talos render-config k8s-0   # inspection : la section logging doit apparaître
```
Attendu : exit 0 partout ; le rendu Talos contient `logging.destinations`.

- [ ] **Étape 9 : commit + PR (sans appliquer Talos)**

```bash
git add kubernetes/apps/observability/kustomization.yaml \
        kubernetes/apps/observability/talos-logs-relay \
        talos/main/cluster.yaml.j2
git commit -m "feat(observability): ship Talos logs to VictoriaLogs"
```

- [ ] **Étape 10 : déployer et vérifier (après merge, un nœud à la fois)**

```bash
flux reconcile kustomization talos-logs-relay -n observability
kubectl -n observability get ds talos-logs-relay   # attendu 4/4 (k8s-0..3)
just talos apply-node k8s-0                        # puis k8s-1, k8s-2, k8s-3
```
Après chaque nœud, vérifier dans Grafana (datasource VictoriaLogs) :
```logsql
node:k8s-0 AND talos-service:*
```
Attendu : des lignes `kubelet`, `etcd`, `machined`, etc., avec les labels `node`, `talos-service`, `facility`. Vérifier aussi l'absence de `Too many open files` / backlog saturé dans les logs du DaemonSet.

**Rollback :** retirer la section `machine.logging` (apply Talos), puis revert de la PR. Les fichiers hostPath `/var/lib/talos-logs-relay` peuvent rester (nettoyage manuel optionnel).

**Risque :** l'apply Talos peut déclencher un reboot selon les champs modifiés ; faire nœud par nœud. Surveiller la rétention VictoriaLogs (`14d`, PVC 20Gi) : les logs Talos peuvent représenter plusieurs Go/jour.

---

## Chantier 10 — kopiur : `execution.mode: Central` (bloqué upstream)

**PRs upstream :** #12138 (prérequis), #12185 (`Central`) — **Effort :** 2-3 h après déblocage — **Risque :** élevé.

**Pourquoi :** en mode `Central`, les movers tournent dans `kopiur-system` : plus aucun pod de mover ni credential de dépôt n'entre dans les namespaces applicatifs. C'est le principal gain de sécurité de kopiur 0.11.

**Blocage vérifié :** le chart Miroir `0.12.13` n'expose **pas** d'`extraArgs` pour le sidecar `csi-provisioner` :
```bash
helm show values oci://ghcr.io/home-operations/charts/miroir --version 0.12.13 | sed -n '146,175p'
# sidecars.provisioner: image, timeout, resources — rien d'autre.
# Les extraArgs: [] des lignes 142 et 249 sont le conteneur controller et l'agent.
```
Or `CrossNamespaceVolumeDataSource` est **toujours alpha en 1.37** et exige `--feature-gates=CrossNamespaceVolumeDataSource=true` sur le csi-provisioner. Sans ce flag, les PVC temporaires cross-namespace restent `Pending`.

**Files (quand débloqué) :**
- Modify (upstream) : chart `home-operations/miroir` — `sidecars.provisioner.extraArgs` ou un toggle dédié.
- Modify: `talos/main/controlplane.yaml.j2` (feature gates apiserver + controller-manager).
- Modify: `kubernetes/apps/miroir-system/miroir/app/helmrelease.yaml` (flag provisioner).
- Modify: `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml` (`spec.execution.mode: Central`).

**Interfaces:**
- Consomme : `ReferenceGrant` (CRD fourni par Gateway API/Envoy Gateway), le `SnapshotPolicy` existant (`volumeSnapshotClassName: miroir` → `copyMethod: Snapshot`, compatible).
- Produit : plus aucun mover dans les namespaces applicatifs.

- [ ] **Étape 1 : ouvrir la demande upstream Miroir**

Demander `sidecars.provisioner.extraArgs` (ou `crossNamespaceVolumeDataSource: true`) dans `home-operations/miroir`. Référencer KEP-3294 et kopiur #12138.

- [ ] **Étape 2 : activer les gates Kubernetes (Talos)**

Dans `talos/main/controlplane.yaml.j2`, sous `cluster.apiServer.extraArgs` et `cluster.controllerManager.extraArgs` :

```yaml
      feature-gates: CrossNamespaceVolumeDataSource=true
```
(Conserver les args existants : `enable-aggregator-routing`, `bind-address`.)

- [ ] **Étape 3 : vérifier le CRD ReferenceGrant**

```bash
kubectl get crd referencegrants.gateway.networking.k8s.io
kubectl api-resources | grep -i referencegrant
```
Attendu : le CRD existe (Envoy Gateway l'installe). Sinon, le provisioner ne devient jamais Ready.

- [ ] **Étape 4 : activer le flag sur le provisioner Miroir**

Une fois le chart mis à jour :

```yaml
    sidecars:
      provisioner:
        extraArgs:
          - --feature-gates=CrossNamespaceVolumeDataSource=true
```

- [ ] **Étape 5 : tester sur une seule app à faible risque**

Choisir `memini` (UID 65532 déjà géré) ou `docling-serve`. Ajouter au `ClusterRepository` :

```yaml
  execution:
    mode: Central
```
Lancer un snapshot manuel, vérifier :
- le mover tourne dans `kopiur-system` (pas dans le namespace de l'app) ;
- la restauration (supprimer le PVC de test et le recréer via le populator `Restore`) ;
- `kubectl -n kopiur-system get pvc` : la PVC temporaire est bien supprimée après coup.

- [ ] **Étape 6 : généraliser aux 28 apps**

Une fois le test concluant, garder `Central` global (le champ est au niveau du ClusterRepository). Surveiller les snapshots horaires pendant 24 h.

**Rollback :** retirer `execution.mode` (retour `InNamespace`, comportement actuel). Les gates Talos peuvent rester (sans effet si le flag provisioner est retiré).

**Notes de compatibilité :**
- `copyMethod: Direct` et les sources `stream` ne peuvent pas quitter le namespace (échec attendu). Le composant utilise `volumeSnapshotClassName: miroir` → snapshot, donc compatible.
- Le cache mover `mode: Persistent` reste dans `kopiur-system`.
- Ne pas activer `Central` avant que le chart Miroir expose le flag : le résultat serait des backups bloqués, pas une dégradation silencieuse.

---

## Déjà couvert — point 2 (kube-apiserver histogram drops)

Le bloc `kubeApiServer.serviceMonitor.metricRelabelings` **existe déjà** dans `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml:51-69` et couvre déjà plus large qu'onedr0p #12246 :

| Règle | Couvre |
|---|---|
| `(apiserver\|etcd\|rest_client)_request(\|_sli\|_slo)_duration_seconds_bucket` | tous les buckets de requêtes (onedr0p n'en drop qu'une partie via `le`) |
| `(apiserver_response_sizes_bucket\|apiserver_watch_events_sizes_bucket)` | buckets de tailles |
| `apiserver_(watch_events_dispatch\|storage_list\|watch_list)_duration_seconds_bucket`, `apiserver_watch_cache_(read_wait_seconds\|initialization_duration_seconds)_bucket`, `apiserver_request_body_size_bytes_bucket` | buckets watch/storage |

Le commentaire inline indique que les `_sum`/`_count` sont **volontairement conservés** (ils servent aux moyennes/rates). Le delta restant d'onedr0p serait de dropper ces `_sum`/`_count`, soit quelques séries seulement, au prix de la perte des moyennes. **Aucune action recommandée.**

Si l'utilisateur veut tout de même l'alignement strict upstream, ajouter cette quatrième règle (et seulement elle) :

```yaml
          - action: drop
            sourceLabels: ["__name__"]
            regex: (apiserver_response_sizes|apiserver_watch_events_sizes|apiserver_storage_list_duration_seconds|apiserver_watch_cache_initialization_duration_seconds|apiserver_watch_cache_read_wait_seconds|apiserver_watch_events_dispatch_duration_seconds|apiserver_watch_list_duration_seconds|apiserver_request_body_size_bytes|etcd_request_duration_seconds)_(count|sum)
```

---

## Non retenus (et pourquoi)

| Sujet upstream | Raison |
|---|---|
| **ArtifactGenerator par app + ExternalArtifact** (#12207/#12215) + **source-watcher** (#12208) | ~160 `ks.yaml` à migrer, change le sync path et le chemin des composants. Le `Receiver` GitHub existant (`kubernetes/apps/flux-system/flux-instance/app/receiver.yaml`) couvre déjà la latence webhook. |
| **Migration victoria-metrics-k8s-stack** (#12260) | Trop gros ; KPS + prompp fonctionne, et le chantier 7 suffit pour la rétention. |
| **XOR2 chunkEncoding** (#12247) | Non applicable : Prometheus tourne avec prompp, pas le TSDB upstream. |
| **Postgres 19** (#12237) | Bump majeur = dump/restore. Le composant épingle `ghcr.io/cloudnative-pg/postgresql:18.4` (`kubernetes/components/postgres/cluster.yaml`). À planifier séparément. |
| **ClusterImageCatalog** (#12236) | Gain faible : l'image est déjà centralisée dans le composant. |
| **mise tasks au lieu de just** (#12089) | Préférence personnelle, pas de gain opérationnel. |
| **Désactiver SELinux + audit kernel** (#12175) | Trade-off sécurité pour un gain marginal. |
| **HA MCP en app séparée** (#12257) | Passe déjà par le gateway litellm MCP. |
| **StatefulSet + claimTemplate restore-backed** (#12258) | Le besoin est déjà couvert par PVC + populator `Restore` (`kubernetes/components/kopiur/backup`). Si migration un jour : ajouter `podManagementPolicy: Parallel`, sinon un pod non-Ready bloque le remplacement. |
| **Notification v1** | Déjà fait (`notification.toolkit.fluxcd.io/v1` dans les composants `alerts`). |
| **unifi-mcp** | Déjà présent dans litellm. |

---

## Ordre d'exécution recommandé

| # | Chantier | Effort | Risque | Dépendance |
|---|---|---|---|---|
| 3 | Hubble labels + buffer | 15 min | faible | aucune |
| 4 | Envoy NodePorts | 5 min | faible | aucune |
| 6 | Reloader annotations | 5 min | faible | aucune |
| 8 | Doc zeroscaler | 5 min | nul | aucune |
| 5 | CI flate | 20 min | faible | aucune (mais merger tôt pour protéger les suivants) |
| 7 | Rétention 90 j | 15 min | moyen | mesure disque |
| 9 | Talos logs relay | ~1 h | moyen | ClusterIP libre, rollout Talos |
| 10 | kopiur Central | 2-3 h | élevé | **bloqué** chart Miroir |

## Self-review

- **Couverture** : les 11 points du rapport sont traités (1 fait, 2 déjà couvert, 3-10 planifiés, 11 non retenu).
- **Placeholders** : aucun « TODO » ; chaque snippet est complet et copiable.
- **Cohérence** : l'IP `10.43.0.60` est répétée à l'identique dans le Service et la config Talos ; l'host VictoriaLogs est celui vérifié dans le collector existant ; les versions citées sont celles lues dans le repo.
