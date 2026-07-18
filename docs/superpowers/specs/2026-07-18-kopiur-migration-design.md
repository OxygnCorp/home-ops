# Design : Remplacement de volsync par kopiur

**Date** : 2026-07-18
**Statut** : Validé (design approuvé)
**Auteur** : Puchu (agent IA)
**Scope** : Déployer l'operator kopiur + un component réutilisable, et migrer une app pilote (`convertx`). La généralisation aux 23 autres apps fera l'objet d'un plan séparé.

## Contexte

Le cluster utilise actuellement **volsync** (fork `perfectra1n/volsync` v0.17.11, chart 0.18.5) comme operator de backup Kopia. 24 apps à travers 7 namespaces dépendent du component `kubernetes/components/volsync/` qui materialise un `ReplicationSource` + `ReplicationDestination` + PVC + ExternalSecret par app.

**kopiur** (https://github.com/home-operations/kopiur) est un operator Kopia-natif écrit en Rust par la communauté `home-operations`. Il propose :
- Une API CRD moderne (`SnapshotPolicy`, `SnapshotSchedule`, `Snapshot`, `Restore`, `ClusterRepository`, `Maintenance`, `RepositoryReplication`)
- Un modèle de **repository partagé** via `ClusterRepository` (vs 1 repo kopia par app côté volsync)
- Un admission webhook self-signed TLS (pas besoin de cert-manager)
- Une Kopia UI native intégrée via `spec.server`
- Maintenance kopia automatique (plus de `KopiaMaintenance` séparée)
- Deletion protection (circuit breaker contre les suppressions de masse)

## Objectifs

1. Déployer l'operator kopiur sans impacter le setup volsync existant.
2. Créer un component `kubernetes/components/kopiur/` réutilisable pour les futures migrations.
3. Migrer `convertx` (app self-hosted, 5Gi, peu critique) comme validateur end-to-end.
4. Valider la solution avant généralisation.

## Non-objectifs

- Migration des 23 autres apps actuellement sous volsync (plan séparé).
- Suppression du namespace `volsync-system` et des CRDs volsync (plan séparé).
- Tuning avancé de la rétention par app.
- Activation d'OTLP / deep verification / RepositoryReplication.

## Décisions arrêtées

| Décision | Choix | Raison |
|---|---|---|
| Backend | NFS inline filesystem sur `funkstation.internal:/volume1/Kopiur` | Réutilise l'infra NAS existante, kopiur supporte nativement `backend.filesystem.volume.nfs` (pas besoin de PVC ni StorageClass RWX) |
| App pilote | `convertx` (self-hosted, 5Gi) | App simple, peu critique, représentative du cas général |
| Snapshots volsync existants | Conservés en lecture seule | volsync reste déployé pendant la phase pilote ; consultation via ancienne Kopia UI |
| Kopia UI | Native kopiur via `spec.server` sur le ClusterRepository | Remplace l'app dédiée `kopia/` actuelle |
| Nom du ClusterRepository | `nas` | Réflecte le backend (NAS Synology funkstation) |
| Path NFS | `/volume1/Kopiur` (nouveau sous-dossier) | Séparation propre avec `/volume1/Volsync` (volsync reste sur son path actuel) |
| Timezone | `Europe/Paris` | Match la localisation du cluster |
| Stratégie de PR | 2 PRs séparées (infra puis convertx) | Permet de valider l'infra indépendamment de la migration app |

## Architecture cible

```
kubernetes/
├── apps/
│   ├── kopiur-system/                         # NOUVEAU
│   │   ├── kustomization.yaml
│   │   ├── namespace.yaml
│   │   └── kopiur/
│   │       ├── ks.yaml                        # 2 Flux Kustomizations: app + repository
│   │       ├── app/
│   │       │   ├── kustomization.yaml
│   │       │   ├── ocirepository.yaml
│   │       │   └── helmrelease.yaml
│   │       └── repository/
│   │           ├── kustomization.yaml
│   │           ├── clusterrepository.yaml
│   │           └── externalsecret.yaml
│   ├── volsync-system/                        # INVARIANT pendant la phase pilote
│   └── self-hosted/convertx/
│       └── ks.yaml                            # PR 2: components/volsync → components/kopiur/backup
├── components/
│   ├── volsync/                               # INVARIANT (23 autres apps)
│   └── kopiur/                                # NOUVEAU
│       ├── backup/                            # Component per-app
│       │   ├── kustomization.yaml
│       │   ├── pvc.yaml
│       │   ├── restore.yaml
│       │   ├── snapshotpolicy.yaml
│       │   └── snapshotschedule.yaml
│       └── secret/                            # Component namespace-level (appliqué sur kopiur-system)
│           ├── kustomization.yaml
│           └── externalsecret.yaml
```

### Comparaison volsync vs kopiur

| Aspect | volsync | kopiur |
|---|---|---|
| Repo Kopia | 1 par app (`${APP}-volsync-secret`) | 1 partagé (`ClusterRepository/nas`) |
| Schedule | `ReplicationSource.trigger.schedule` | `SnapshotSchedule` (CRD séparée) |
| Restore | `ReplicationDestination` (manual restore-once) | `Restore` (deploy-or-restore via PVC `dataSourceRef`) |
| Maintenance | `KopiaMaintenance` CRDs séparées | Managé automatiquement par l'operator |
| Identity par app | `sourceIdentity.sourceName` | CEL `identityDefaults.hostnameExpr: "namespace"` |
| Secret Kopia | `${APP}-volsync-secret` dans le namespace app | `kopiur-repository-secret` dans `kopiur-system`, projeté via `credentialProjection` |
| Webhook admission | n/a | Self-signed TLS par défaut, `failurePolicy: Fail` |

## Composants détaillés

### `components/kopiur/backup/`

Component kustomize référencé depuis chaque `ks.yaml` d'app à backuper.

**`kustomization.yaml`** :
```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./snapshotpolicy.yaml
  - ./snapshotschedule.yaml
  - ./pvc.yaml
  - ./restore.yaml
```

**`snapshotpolicy.yaml`** :
```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotPolicy
metadata:
  name: ${APP}
spec:
  compression:
    compressor: zstd
  mover:
    cache:
      capacity: ${KOPIUR_CAPACITY:=5Gi}
      mode: Persistent
      storageClassName: ${KOPIUR_CACHE_STORAGECLASS:=openebs-hostpath}
  repository:
    kind: ClusterRepository
    name: ${KOPIUR_REPOSITORY:=nas}
  retention:
    keepLatest: 3
    keepHourly: 24
    keepDaily: 7
    keepWeekly: 4
  sources:
    - pvc:
        name: ${APP}
  volumeSnapshotClassName: ${KOPIUR_SNAPSHOTCLASS:=csi-ceph-blockpool}
```

Notes :
- Pas de `mover.securityContext` per-app : porté par `moverDefaults` au niveau du ClusterRepository (uniformité).
- Rétention GFS plus riche que volsync (`keepLatest: 3`, `keepWeekly: 4` en plus).

**`snapshotschedule.yaml`** :
```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: SnapshotSchedule
metadata:
  name: ${APP}
spec:
  policyRef:
    name: ${APP}
  schedule:
    cron: H * * * *
```

Note : `H * * * *` est la syntaxe Jenkins-style kopiur pour "hourly with jitter" — évite que toutes les apps ne backup au même top d'heure.

**`pvc.yaml`** :
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${APP}
spec:
  accessModes:
    - ${KOPIUR_ACCESSMODES:=ReadWriteOnce}
  dataSourceRef:
    apiGroup: kopiur.home-operations.com
    kind: Restore
    name: ${APP}
  resources:
    requests:
      storage: ${KOPIUR_CAPACITY:=5Gi}
  storageClassName: ${KOPIUR_STORAGECLASS:=ceph-block}
```

**`restore.yaml`** :
```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata:
  name: ${APP}
spec:
  policy:
    onMissingSnapshot: Continue
  source:
    fromPolicy:
      name: ${APP}
      offset: 0
  target:
    populator: {}
```

### `components/kopiur/secret/`

Component namespace-level, appliqué une seule fois sur `kopiur-system` (pas sur chaque namespace d'app).

**`kustomization.yaml`** :
```yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./externalsecret.yaml
```

**`externalsecret.yaml`** :
```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kopiur-repository
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: kopiur-repository-secret
    template:
      data:
        KOPIA_PASSWORD: "{{ .KOPIA_PASSWORD }}"
  dataFrom:
    - extract:
        key: kopiur
```

Note : Un seul secret `KOPIA_PASSWORD` (pas d'AWS creds, backend filesystem).

### Variables du component

Substituées via `postBuild.substitute` dans chaque `ks.yaml` d'app :

| Variable | Default | Équivalent volsync | Notes |
|---|---|---|---|
| `APP` | (requis) | `APP` | Nom de l'app |
| `KOPIUR_CAPACITY` | `5Gi` | `VOLSYNC_CAPACITY` | Taille PVC source + cache |
| `KOPIUR_ACCESSMODES` | `ReadWriteOnce` | `VOLSYNC_ACCESSMODES` | |
| `KOPIUR_STORAGECLASS` | `ceph-block` | `VOLSYNC_STORAGECLASS` | PVC source |
| `KOPIUR_SNAPSHOTCLASS` | `csi-ceph-blockpool` | `VOLSYNC_SNAPSHOTCLASS` | VolumeSnapshotClass |
| `KOPIUR_CACHE_STORAGECLASS` | `openebs-hostpath` | `VOLSYNC_CACHE_SNAPSHOTCLASS` | Cache mover |
| `KOPIUR_REPOSITORY` | `nas` | n/a | Nom du ClusterRepository partagé |

**Règle de migration d'une app** : changer dans son `ks.yaml` :
- `components/volsync` → `components/kopiur/backup`
- `dependsOn: { name: volsync, namespace: volsync-system }` → `dependsOn: { name: kopiur, namespace: kopiur-system }`
- Renommer les variables `VOLSYNC_*` → `KOPIUR_*`

### `apps/kopiur-system/`

**`namespace.yaml`** :
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: _
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

**`kustomization.yaml`** :
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: kopiur-system
components:
  - ../../components/alerts
  - ../../components/kopiur/secret
resources:
  - ./namespace.yaml
  - ./kopiur/ks.yaml
```

**`kopiur/ks.yaml`** — Deux Flux Kustomizations (`app` pour l'operator, `repository` pour le ClusterRepository qui dépend de l'operator) :
```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kopiur
spec:
  healthChecks:
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: kopiur
      namespace: kopiur-system
  interval: 1h
  path: ./kubernetes/apps/kopiur-system/kopiur/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: kopiur-system
  wait: false
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: kopiur-repository
spec:
  dependsOn:
    - name: kopiur
  interval: 1h
  path: ./kubernetes/apps/kopiur-system/kopiur/repository
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: kopiur-system
  wait: false
```

**`kopiur/app/kustomization.yaml`** :
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
```

**`kopiur/app/ocirepository.yaml`** :
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: kopiur
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.7.5   # à valider au moment de l'implémentation : dernière version dispo sur oci://ghcr.io/home-operations/charts/kopiur
  url: oci://ghcr.io/home-operations/charts/kopiur
```

**`kopiur/app/helmrelease.yaml`** :
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: kopiur
spec:
  chartRef:
    kind: OCIRepository
    name: kopiur
  interval: 1h
  values:
    monitoring:
      dashboards:
        enabled: true
        grafanaOperator:
          enabled: true
          matchLabels:
            dashboards: grafana   # à valider : labels effectifs du GrafanaOperator local
      prometheusRule:
        enabled: true
      serviceMonitor:
        enabled: true
    podSecurityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
      fsGroupChangePolicy: OnRootMismatch
    resources:
      requests:
        cpu: 100m
      limits:
        memory: 2Gi
```

Note : pas besoin d'`extraVolumes` sur le controller. Le backend NFS est monté inline directement par les mover Jobs, le controller lui-même n'accède pas au repo filesystem (cf `docs/backends/filesystem.md` : "A PVC- or NFS-backed repo is **not** reachable from the controller, so the operator runs the connect/create in a short mover Job that mounts the volume").

**`kopiur/repository/clusterrepository.yaml`** :
```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: ClusterRepository
metadata:
  name: nas
spec:
  allowedNamespaces:
    all: true
  backend:
    filesystem:
      path: /mnt/repository
      volume:
        nfs:
          server: funkstation.internal
          path: /volume1/Kopiur
  encryption:
    passwordSecretRef:
      name: kopiur-repository-secret
      namespace: kopiur-system
      key: KOPIA_PASSWORD
  create:
    enabled: true
  identityDefaults:
    hostnameExpr: "namespace"
    usernameExpr: "namespace + '-' + policyName"
  scheduleDefaults:
    timezone: Europe/Paris
  moverDefaults:
    securityContext:
      runAsUser: 1024
      runAsGroup: 100
    podSecurityContext:
      runAsNonRoot: true
      fsGroup: 100   # no-op sur NFS mais garde la cohérence avec volsync
  server: {}   # active la Kopia UI native (Deployment + Service dans kopiur-system). Presence du bloc = activé ; pas de champ `enabled` (cf docs/repositories.md#server--the-kopia-web-ui)
  deletionProtection:
    threshold: 25
    ```

Décisions de configuration clés :
- **UID/GID `1024:100`** identiques à volsync : réutilisation directe de l'ownership NFS existant. Le sous-dossier `/volume1/Kopiur` doit être créé avec `chown 1024:100` explicite (l'héritage n'est pas automatique sur Linux sans SGID bit sur le parent).
- **`identityDefaults` CEL** : chaque app écrit sous `<namespace>-<policyName>@<namespace>:/...`, isolation propre dans le repo partagé. Ex: convertx → `self-hosted-convertx@self-hosted:/...`.
- **`server: {}`** : active la Kopia UI native — la présence du bloc suffit, pas de champ `enabled`. Le chart livre déjà le RBAC pour gérer Deployment/Service/ConfigMap/Secret de la UI.
- **`deletionProtection.threshold: 25`** : protège contre une suppression accidentelle en masse (au-dessus du défaut `10`, adapté au volume d'apps à venir).

### Migration convertx

**`apps/self-hosted/convertx/ks.yaml`** (avant → après) :

```diff
 spec:
   components:
-    - ../../../../components/volsync
+    - ../../../../components/kopiur/backup
   dependsOn:
     - name: rook-ceph-cluster
       namespace: rook-ceph
-    - name: volsync
-      namespace: volsync-system
+    - name: kopiur
+      namespace: kopiur-system
   postBuild:
     substitute:
       APP: convertx
-      VOLSYNC_CAPACITY: 5Gi
+      KOPIUR_CAPACITY: 5Gi
```

#### Gestion de la PVC existante

La PVC convertx actuelle a `spec.dataSourceRef` pointant vers `ReplicationDestination/convertx-dst` (volsync). Le nouveau manifest component kopiur déclare `dataSourceRef: Restore/convertx`. Côté kubernetes, `dataSourceRef` est **immutable après création** — le champ est ignoré sur une PVC existante.

Comportement attendu côté Flux : un diff cosmétique sur `dataSourceRef` qui ne déclenche pas de recréation de PVC. En pratique, la PVC existante reste en place, convertx garde ses données, seul l'orchestrateur de backup change.

Le manifest `Restore convertx` est créé par le component mais reste inopérant tant que la PVC existe (`onMissingSnapshot: Continue`).

#### Étapes préparatoires manuelles (avant apply de la PR 2)

1. Créer le 1Password item `kopiur` avec `KOPIA_PASSWORD` (nouveau password recommandé, différent de volsync-template pour isolation).
2. Créer le dossier `/volume1/Kopiur` sur la funkstation avec ownership `1024:100` :
   ```bash
   # sur funkstation
   mkdir -p /volume1/Kopiur
   chown 1024:100 /volume1/Kopiur
   chmod 750 /volume1/Kopiur
   ```
3. Effectuer un dernier snapshot volsync de convertx (point de restore de référence au cas où) :
   ```bash
   kubectl -n self-hosted patch replicationsource convertx --type=merge \
     -p '{"spec":{"trigger":{"manual":"force-'"$(date +%s)"'"}}}'
   ```
4. (Optionnel) Scale down convertx pour un apply propre :
   ```bash
   kubectl -n self-hosted scale deploy/convertx --replicas=0
   ```

## Plan de validation

### Phase 1 (PR 1) — Validation de l'infra kopiur

| # | Test | Commande | Critère de succès |
|---|---|---|---|
| 1 | CRDs enregistrés | `kubectl get crd \| grep kopiur.home-operations.com` | 8 CRDs présents |
| 2 | Operator prêt | `kubectl -n kopiur-system rollout status deploy/kopiur-controller deploy/kopiur-webhook` | Both Running |
| 3 | ExternalSecret synchronisé | `kubectl -n kopiur-system get externalsecret kopiur-repository` | `SecretSynced=True` |
| 4 | ClusterRepository Ready | `kubectl wait clusterrepository/nas --for=condition=Ready --timeout=3m` | `Ready=True` |
| 5 | Repo initialisé sur NFS | `ls /volume1/Kopiur` sur funkstation | Présence de blobs kopia (`.kopia/`) |
| 6 | Kopia UI accessible | `kubectl -n kopiur-system port-forward svc/<kopia-ui-svc> 8080:80` puis navigateur | UI se charge, repo connecté |
| 7 | `flate` local passe | `mise exec -- flate test ks --path ./kubernetes/apps/kopiur-system` && `mise exec -- flate test hr --path ./kubernetes/apps/kopiur-system` | Pas d'erreur |

### Phase 2 (PR 2) — Validation de la migration convertx

| # | Test | Commande | Critère de succès |
|---|---|---|---|
| 1 | Flux reconcilie | `flux get ks -n self-hosted convertx` | `Ready=True` |
| 2 | CRs kopiur créés | `kubectl -n self-hosted get snapshotpolicy,snapshotschedule,restore convertx` | 3 ressources Ready |
| 3 | Schedule computed | `kubectl -n self-hosted get snapshotschedule convertx -o jsonpath={.status.nextSchedule}` | Slot cron calculé |
| 4 | PVC inchangée | `kubectl -n self-hosted get pvc convertx` | Toujours bound, même taille et âge |
| 5 | Premier snapshot | Déclenché au prochain slot `H * * * *` ou forcé via création manuelle d'un objet `Snapshot` (réf. `deploy/examples/01-single-pvc-scheduled.yaml`) | `Snapshot Phase=Succeeded`, `status.stats.bytesNew > 0` |
| 6 | Données sur NFS | `find /volume1/Kopiur -name "*.f"` \| head` | Blobs kopia écrits |
| 7 | Snapshot visible Kopia UI | Refresh UI | Snapshot listing sous identity `self-hosted-convertx@self-hosted` |
| 8 | `flate` local passe | `mise exec -- flate test ks --path ./kubernetes/apps/self-hosted/convertx` | Pas d'erreur |
| 9 | (Recommandé) Test restore | Scale down convertx, delete PVC, `kubectl patch restore convertx -p '{...}'` pour re-trigger, vérifier données | Données restaurées correctement |
| 10 | Volsync intact | `kubectl -n self-hosted get replicationsource,replicationdestination` | Absent (supprimé par component removal) ; autres apps toujours backup par volsync |

### Critères de généralisation (go/no-go pour les 23 autres apps)

- ✅ Tests Phase 1 verts
- ✅ Tests Phase 2 (1-8) verts
- ✅ Aucune erreur récurrente dans `kubectl logs -n kopiur-system deploy/kopiur-controller` après 24h
- ✅ Un cycle complet de rétention (24h) s'est exécuté sans erreur
- ✅ Kopia UI browsable et fonctionnelle
- 🟡 Test restore réussi (fortement recommandé avant généralisation)

## Coexistence volsync / kopiur (pendant la phase pilote)

| Aspect | volsync | kopiur |
|---|---|---|
| Namespace | `volsync-system` | `kopiur-system` |
| Path NFS | `/volume1/Volsync` | `/volume1/Kopiur` |
| Kopia repo password | `KOPIA_PASSWORD` (1Password item `volsync-template`) | `KOPIA_PASSWORD` (1Password item `kopiur`, password différent) |
| CRDs | `volsync.backube/v1alpha1` | `kopiur.home-operations.com/v1alpha1` |
| Operator image | `ghcr.io/perfectra1n/volsync` | `ghcr.io/home-operations/kopiur-controller` |

Aucun conflit possible : deux repos kopia physiquement et logiquement séparés, deux operators indépendants.

## Stratégie de PR

### PR 1 — Infra kopiur (sans toucher aux apps)

Contenu :
- `kubernetes/components/kopiur/{backup,secret}/*`
- `kubernetes/apps/kopiur-system/*` (namespace, ks, app, repository)

Prérequis manuels (à effectuer avant merge) :
- Créer 1Password item `kopiur`
- Créer dossier `/volume1/Kopiur` sur funkstation

Validation : tests Phase 1 (1-7).

### PR 2 — Migration convertx

Contenu :
- Modification de `kubernetes/apps/self-hosted/convertx/ks.yaml` (uniquement)

Dépendance : PR 1 mergée et validée.

Validation : tests Phase 2 (1-10).

## Risques et mitigations

| Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|
| Permission denied sur `/volume1/Kopiur` | Moyenne | Bloquant | Réutiliser UID `1024:100` (déjà propriétaire de `/volume1/Volsync`) ; `chown` du sous-dossier à la création |
| KOPIA_PASSWORD perdu | Faible | Critique | 1Password item dédié `kopiur`, backup du Secret Kubernetes |
| Webhook kopiur (`failurePolicy: Fail`) bloque les CR kopiur en cas d'indispo | Faible | Bloquant | PDB activé (1 replica + PDB) — acceptable en phase pilote |
| Mauvaise config CEL `identityDefaults` | Faible | Bloquant | Webhook valide à l'admission ; testé d'abord sur convertx |
| Incompatibilité chart version 0.7.5 avec API server 1.32+ | Faible | Bloquant | Vérifier compat Kubernetes >= 1.32 (kopiur requiert 1.24+, WatchList GA en 1.34) |
| Conflit `dataSourceRef` PVC convertx | Faible | Cosmétique | `dataSourceRef` est immutable, Flux reporte un diff mais ne recrée pas la PVC |
| Grafana dashboard non détectée par grafana-operator | Moyenne | Mineur | Vérifier les `matchLabels` du Grafana local avant merge |
| Snapshot schedule `H * * * *` syntaxe non supportée | Faible | Bloquant | Vérifier doc kopiur SnapshotSchedule au moment de l'implémentation |

## Décommissionnement volsync (hors scope initial)

À traiter dans un plan séparé après validation pilote et généralisation :
1. Pour chaque app : dernier snapshot volsync puis migration du `ks.yaml`.
2. Une fois toutes les apps migrées : `flux suspend kustomization volsync -n volsync-system`.
3. Suppression de `kubernetes/apps/volsync-system/` et `kubernetes/components/volsync/`.
4. Cleanup des CRDs : `kubectl delete crd $(kubectl get crd -o name | grep volsync.backube)`.
5. (Optionnel) Archive ou suppression de `/volume1/Volsync` sur la funkstation.

## Références

- kopiur chart README : https://github.com/home-operations/kopiur/blob/main/deploy/helm/kopiur/README.md
- kopiur install guide : https://github.com/home-operations/kopiur/blob/main/docs/install.md
- kopiur filesystem backend : https://github.com/home-operations/kopiur/blob/main/docs/backends/filesystem.md
- kopiur repositories guide : https://github.com/home-operations/kopiur/blob/main/docs/repositories.md
- onedr0p reference (component) : https://github.com/onedr0p/home-ops/tree/main/kubernetes/components/kopiur
- onedr0p reference (app) : https://github.com/onedr0p/home-ops/tree/main/kubernetes/apps/kopiur-system
