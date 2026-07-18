# kopiur Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace volsync with kopiur on the home-ops cluster, validated on a single pilot app (`convertx`) before generalization.

**Architecture:** Deploy kopiur operator in a new `kopiur-system` namespace alongside the existing volsync (read-only during pilot). A shared `ClusterRepository/nas` backed by inline NFS filesystem (`funkstation.internal:/volume1/Kopiur`) holds all backups. A new reusable component `kubernetes/components/kopiur/` exposes per-app backup. Migration of one app (`convertx`) validates end-to-end before scaling to the other 23 apps.

**Tech Stack:** kopiur v0.7.5 (chart from `oci://ghcr.io/home-operations/charts/kopiur`), Flux GitOps, kustomize components, external-secrets + 1Password, Kopia filesystem backend over NFS.

## Global Constraints

These apply to every task implicitly; copy values verbatim, do not invent:

- **ClusterRepository name**: `nas` (not `default`, not `expanse`)
- **NFS server**: `funkstation.internal`
- **NFS path**: `/volume1/Kopiur` (NEW subfolder; do NOT reuse `/volume1/Volsync`)
- **Mover UID/GID**: `1024:100` (matches volsync, reuses existing NFS ownership)
- **ExternalSecret store**: `ClusterSecretStore/onepassword` (local convention, NOT `onepassword-connect`)
- **1Password item key**: `kopiur` (NEW item, password different from `volsync-template`)
- **kopiur chart version**: `0.7.5` (pinned — latest available on `oci://ghcr.io/home-operations/charts/kopiur` at 2026-07-18)
- **Grafana matchLabel**: `grafana.internal/instance: grafana` (verified against `apps/observability/grafana/instance/grafanadashboard.yaml`)
- **Timezone**: `Europe/Paris`
- **Cache StorageClass**: `openebs-hostpath` (matches `VOLSYNC_CACHE_SNAPSHOTCLASS` from volsync)
- **Source StorageClass**: `ceph-block`
- **VolumeSnapshot class**: `csi-ceph-blockpool`
- **Target namespace for operator**: `kopiur-system` (NEW; do NOT touch `volsync-system`)
- **Flatten tool**: `mise exec -- flate ...` (see AGENTS.md)

## Prerequisites (manual, before starting Phase A)

These cannot be automated; verify before Task 1.

- [ ] **1Password item created**: vault item `kopiur` with field `KOPIA_PASSWORD` (random long password, distinct from `volsync-template`). Note the 1Password Connect integration uses `ClusterSecretStore/onepassword` so the item must live in the vault that store points to.
- [ ] **NFS folder created on funkstation**: 
  ```bash
  # SSH onto funkstation as admin
  mkdir -p /volume1/Kopiur
  chown 1024:100 /volume1/Kopiur
  chmod 750 /volume1/Kopiur
  ls -ld /volume1/Kopiur   # verify: drwxr-x---  1024 100  ...
  ```
- [ ] **1Password Connect healthy in cluster**: `kubectl get clustersecretstore onepassword -o jsonpath='{.status.conditions[-1].type}{"="}{.status.conditions[-1].status}{"\n"}'` should show `Ready=True`.

---

## Phase A — Infrastructure (PR 1)

PR 1 deploys the operator and ClusterRepository. It does NOT touch any app.

### Task 1: Create `components/kopiur/backup/` component

**Files:**
- Create: `kubernetes/components/kopiur/backup/kustomization.yaml`
- Create: `kubernetes/components/kopiur/backup/snapshotpolicy.yaml`
- Create: `kubernetes/components/kopiur/backup/snapshotschedule.yaml`
- Create: `kubernetes/components/kopiur/backup/pvc.yaml`
- Create: `kubernetes/components/kopiur/backup/restore.yaml`

**Interfaces:**
- Consumes: Post-build variables `${APP}`, `${KOPIUR_CAPACITY}`, `${KOPIUR_ACCESSMODES}`, `${KOPIUR_STORAGECLASS}`, `${KOPIUR_SNAPSHOTCLASS}`, `${KOPIUR_CACHE_STORAGECLASS}`, `${KOPIUR_REPOSITORY}` supplied by each app's `ks.yaml` via `postBuild.substitute`.
- Produces: a kustomize Component that an app's `ks.yaml` references as `../../../../components/kopiur/backup`. Renders 4 CRs (SnapshotPolicy, SnapshotSchedule, Restore) + 1 PVC per app.

- [ ] **Step 1.1: Create `kustomization.yaml`**

File: `kubernetes/components/kopiur/backup/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./snapshotpolicy.yaml
  - ./snapshotschedule.yaml
  - ./pvc.yaml
  - ./restore.yaml
```

- [ ] **Step 1.2: Create `snapshotpolicy.yaml`**

File: `kubernetes/components/kopiur/backup/snapshotpolicy.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotpolicy_v1alpha1.json
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

- [ ] **Step 1.3: Create `snapshotschedule.yaml`**

File: `kubernetes/components/kopiur/backup/snapshotschedule.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/snapshotschedule_v1alpha1.json
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

- [ ] **Step 1.4: Create `pvc.yaml`**

File: `kubernetes/components/kopiur/backup/pvc.yaml`

```yaml
---
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

- [ ] **Step 1.5: Create `restore.yaml`**

File: `kubernetes/components/kopiur/backup/restore.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/restore_v1alpha1.json
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

- [ ] **Step 1.6: Commit**

```bash
git add kubernetes/components/kopiur/backup/
git commit -m "feat(kopiur): add reusable backup component

SnapshotPolicy + SnapshotSchedule + Restore + PVC for per-app backups.
References the shared ClusterRepository 'nas' by name (overridable via
KOPIUR_REPOSITORY). GFS retention: 3 latest, 24 hourly, 7 daily, 4 weekly."
```

### Task 2: Create `components/kopiur/secret/` component

**Files:**
- Create: `kubernetes/components/kopiur/secret/kustomization.yaml`
- Create: `kubernetes/components/kopiur/secret/externalsecret.yaml`

**Interfaces:**
- Consumes: 1Password item `kopiur` (must exist before this is applied to the cluster).
- Produces: a kustomize Component applied once at the namespace level (`apps/kopiur-system/kustomization.yaml` references it). Renders the ExternalSecret `kopiur-repository` that materializes Secret `kopiur-repository-secret` in the namespace it's applied to.

- [ ] **Step 2.1: Create `kustomization.yaml`**

File: `kubernetes/components/kopiur/secret/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./externalsecret.yaml
```

- [ ] **Step 2.2: Create `externalsecret.yaml`**

File: `kubernetes/components/kopiur/secret/externalsecret.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
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

- [ ] **Step 2.3: Commit**

```bash
git add kubernetes/components/kopiur/secret/
git commit -m "feat(kopiur): add shared repository secret component

ExternalSecret pulls KOPIA_PASSWORD from 1Password item 'kopiur' into
Secret 'kopiur-repository-secret'. Applied once at kopiur-system
namespace level, referenced by ClusterRepository 'nas'."
```

### Task 3: Create `apps/kopiur-system/` skeleton + namespace

**Files:**
- Create: `kubernetes/apps/kopiur-system/namespace.yaml`
- Create: `kubernetes/apps/kopiur-system/kustomization.yaml`

**Interfaces:**
- Consumes: components `alerts` (existing) and `kopiur/secret` (Task 2).
- Produces: Flux-discoverable app directory that builds into namespace `kopiur-system`. The `kustomization.yaml` references `./kopiur/ks.yaml` (created in Task 4).

- [ ] **Step 3.1: Create `namespace.yaml`**

File: `kubernetes/apps/kopiur-system/namespace.yaml`

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: _
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

Note: `name: _` is replaced by kustomize's `namespace:` directive in the parent `kustomization.yaml`. The prune-disabled annotation matches the `volsync-system` convention so the namespace survives even if the manifest is removed.

- [ ] **Step 3.2: Create `kustomization.yaml`**

File: `kubernetes/apps/kopiur-system/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
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

- [ ] **Step 3.3: Commit**

```bash
git add kubernetes/apps/kopiur-system/namespace.yaml kubernetes/apps/kopiur-system/kustomization.yaml
git commit -m "feat(kopiur): add kopiur-system namespace skeleton

Namespace prune disabled (matches volsync-system convention). Pulls in
alerts + kopiur/secret components. ks.yaml added in next commit."
```

### Task 4: Create `kopiur/ks.yaml` (Flux Kustomizations)

**Files:**
- Create: `kubernetes/apps/kopiur-system/kopiur/ks.yaml`

**Interfaces:**
- Consumes: `./kopiur/app/` (Task 5) and `./kopiur/repository/` (Task 6).
- Produces: two Flux Kustomizations — `kopiur` (operator) and `kopiur-repository` (ClusterRepository, depends on operator).

- [ ] **Step 4.1: Create `ks.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/ks.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
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
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
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

- [ ] **Step 4.2: Commit**

```bash
git add kubernetes/apps/kopiur-system/kopiur/ks.yaml
git commit -m "feat(kopiur): add Flux Kustomizations for operator and repository

'kopiur' Kustomization reconciles the HelmRelease (healthchecked).
'kopiur-repository' depends on 'kopiur' and reconciles the
ClusterRepository once the operator is ready."
```

### Task 5: Create operator deployment (`kopiur/app/`)

**Files:**
- Create: `kubernetes/apps/kopiur-system/kopiur/app/kustomization.yaml`
- Create: `kubernetes/apps/kopiur-system/kopiur/app/ocirepository.yaml`
- Create: `kubernetes/apps/kopiur-system/kopiur/app/helmrelease.yaml`

**Interfaces:**
- Consumes: OCI chart `oci://ghcr.io/home-operations/charts/kopiur` tag `0.7.5`.
- Produces: HelmRelease `kopiur` in `kopiur-system`. Healthchecked by `ks.yaml` (Task 4).

- [ ] **Step 5.1: Create `app/kustomization.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/app/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
```

- [ ] **Step 5.2: Create `app/ocirepository.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/app/ocirepository.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
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
    tag: 0.7.5
  url: oci://ghcr.io/home-operations/charts/kopiur
```

- [ ] **Step 5.3: Create `app/helmrelease.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/app/helmrelease.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
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
            grafana.internal/instance: grafana
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

- [ ] **Step 5.4: Commit**

```bash
git add kubernetes/apps/kopiur-system/kopiur/app/
git commit -m "feat(kopiur): deploy operator via HelmRelease

Chart oci://ghcr.io/home-operations/charts/kopiur:0.7.5. Enables
Grafana dashboard (grafanaOperator, matchLabel 'grafana.internal/instance:
grafana'), PrometheusRule, ServiceMonitor. Webhook uses self-signed TLS
(chart default). Resources: 100m request, 2Gi limit."
```

### Task 6: Create ClusterRepository (`kopiur/repository/`)

**Files:**
- Create: `kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml`
- Create: `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml`

**Interfaces:**
- Consumes: Secret `kopiur-repository-secret` (from ExternalSecret in Task 2, materialized by the `kopiur/secret` component at the namespace level).
- Produces: `ClusterRepository/nas` (cluster-scoped) with backend filesystem over NFS inline, used by all `SnapshotPolicy` resources via `repository.name: nas`.

- [ ] **Step 6.1: Create `repository/kustomization.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml`

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./clusterrepository.yaml
```

Note: No ExternalSecret here — it lives in the `kopiur/secret` component pulled in by the parent `apps/kopiur-system/kustomization.yaml`.

- [ ] **Step 6.2: Create `repository/clusterrepository.yaml`**

File: `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml`

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/clusterrepository_v1alpha1.json
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
      fsGroup: 100
  server: {}
  deletionProtection:
    threshold: 25
```

Key fields:
- `backend.filesystem.volume.nfs` — inline NFS mount synthesized by kopiur on each mover Job; no PVC needed.
- `identityDefaults.hostnameExpr: "namespace"` — each app's snapshots land under identity `<ns>-<policy>@<ns>:/...`.
- `moverDefaults.securityContext.runAsUser: 1024` — matches volsync; NFS path writable without `chown`.
- `server: {}` — presence of the block enables Kopia UI (no `enabled` bool per chart spec).
- `deletionProtection.threshold: 25` — circuit breaker above chart default of 10, sized for 24-app fleet.

- [ ] **Step 6.3: Commit**

```bash
git add kubernetes/apps/kopiur-system/kopiur/repository/
git commit -m "feat(kopiur): add ClusterRepository 'nas'

Shared cluster-scoped repository backed by inline NFS filesystem
(funkstation.internal:/volume1/Kopiur). UID/GID 1024:100 reuses volsync
ownership. CEL identity isolation per namespace. Kopia UI enabled via
'server: {}' presence. Deletion protection threshold 25."
```

### Task 7: Local validation + push branch + open PR 1

- [ ] **Step 7.1: Verify branch state**

```bash
git status
git log --oneline main..HEAD   # should show 6 commits on this branch
```

Expected: working tree clean, 6 commits ahead of `main` for Tasks 1-6.

- [ ] **Step 7.2: Run flate tests (Kustomizations)**

```bash
mise exec -- flate test ks --path ./kubernetes/apps/kopiur-system
```

Expected: PASS, no errors. If a schema error appears for `server: {}` or `volume.nfs`, double-check against the spec's "Décisions de configuration clés" notes and the upstream kopiur docs.

- [ ] **Step 7.3: Run flate tests (HelmReleases)**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/kopiur-system
```

Expected: PASS, no errors.

- [ ] **Step 7.4: Diff against main (sanity check)**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```

Expected: only additions (no changes to existing apps). If `flate diff` reports changes outside `kopiur-system/` or `components/kopiur/`, STOP and investigate.

- [ ] **Step 7.5: Push branch**

```bash
git push -u origin HEAD
```

- [ ] **Step 7.6: Open PR**

```bash
gh pr create \
  --title "feat(kopiur): deploy kopiur operator + ClusterRepository" \
  --body "Implements Phase A of the kopiur migration design (docs/superpowers/specs/2026-07-18-kopiur-migration-design.md).

## What
- New component \`kubernetes/components/kopiur/{backup,secret}\` (reusable per-app + shared-secret components)
- New namespace \`kopiur-system\` with operator HelmRelease (chart 0.7.5) and ClusterRepository \`nas\`
- Backend: inline NFS filesystem on \`funkstation.internal:/volume1/Kopiur\` (NEW subfolder, isolated from volsync's /volume1/Volsync)
- Kopia UI enabled via \`server: {}\` on the ClusterRepository
- Webhook uses chart-default self-signed TLS (no cert-manager dependency)

## What it does NOT change
- volsync remains fully operational (24 apps, operator, KopiaMaintenance, Kopia UI) — read-only during pilot
- No app migration in this PR — that's PR 2 (convertx only)

## Prerequisites (manual, completed before merge)
- [ ] 1Password item \`kopiur\` created with \`KOPIA_PASSWORD\`
- [ ] NFS folder \`/volume1/Kopiur\` created on funkstation with ownership \`1024:100\`

## Validation checklist (run after merge)
1. \`kubectl get crd | grep kopiur.home-operations.com\` → 8 CRDs
2. \`kubectl -n kopiur-system rollout status deploy/kopiur-controller deploy/kopiur-webhook\` → both Running
3. \`kubectl -n kopiur-system get externalsecret kopiur-repository\` → SecretSynced=True
4. \`kubectl wait clusterrepository/nas --for=condition=Ready --timeout=3m\` → Ready=True
5. \`ls /volume1/Kopiur\` on funkstation → kopia blobs (.kopia/)
6. Kopia UI port-forward reachable

Refs: docs/superpowers/specs/2026-07-18-kopiur-migration-design.md" \
  --base main
```

- [ ] **Step 7.7: After PR merge + cluster validation, capture the operator state**

Wait until PR 1 is merged and Phase 1 validation tests 1-6 (spec section "Plan de validation") pass on the cluster. Then proceed to Phase B.

---

## Phase B — Convertx migration (PR 2)

PR 2 starts ONLY after PR 1 is merged and the operator + ClusterRepository are healthy on the cluster.

### Task 8: Take a final volsync snapshot of convertx

This gives a fallback restore point before switching orchestrators.

- [ ] **Step 8.1: Force a volsync snapshot**

```bash
kubectl -n self-hosted patch replicationsource convertx --type=merge \
  -p '{"spec":{"trigger":{"manual":"force-'"$(date +%s)"'"}}}'
```

- [ ] **Step 8.2: Wait for completion**

```bash
kubectl -n self-hosted wait replicationsource convertx --for=jsonpath='{.status.conditions[?(@.type=="Synced")].status}'=True --timeout=10m \
  || kubectl -n self-hosted describe replicationsource convertx
```

Expected: condition `Synced=True` (or whatever volsync-perfectra1n uses; if not, fall back to `kubectl get replicationsource convertx -o yaml` and inspect `.status`).

- [ ] **Step 8.3: Optional precaution — scale down convertx**

```bash
kubectl -n self-hosted scale deploy/convertx --replicas=0
kubectl -n self-hosted wait pod -l app.kubernetes.io/name=convertx --for=delete --timeout=2m
```

Optional but cleaner; skip if you want zero-downtime cutover.

### Task 9: Update convertx ks.yaml

**Files:**
- Modify: `kubernetes/apps/self-hosted/convertx/ks.yaml`

**Interfaces:**
- Consumes: `components/kopiur/backup` (Task 1) + Flux Kustomization `kopiur` (Task 4) + ClusterRepository `nas` (Task 6).
- Produces: convertx now backed up by kopiur instead of volsync.

- [ ] **Step 9.1: Read the current file to confirm starting state**

```bash
cat kubernetes/apps/self-hosted/convertx/ks.yaml
```

Expected content (matches what's currently on main):
```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: convertx
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: convertx
  components:
    - ../../../../components/volsync
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
    - name: volsync
      namespace: volsync-system
  interval: 1h
  path: ./kubernetes/apps/self-hosted/convertx/app
  postBuild:
    substitute:
      APP: convertx
      VOLSYNC_CAPACITY: 5Gi
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: self-hosted
  wait: false
```

- [ ] **Step 9.2: Apply the migration diff**

Edit `kubernetes/apps/self-hosted/convertx/ks.yaml`. Three changes:

1. `components/volsync` → `components/kopiur/backup`
2. `dependsOn` entry `volsync/volsync-system` → `kopiur/kopiur-system`
3. `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY`

After edit, the file must read exactly:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: convertx
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: convertx
  components:
    - ../../../../components/kopiur/backup
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
    - name: kopiur
      namespace: kopiur-system
  interval: 1h
  path: ./kubernetes/apps/self-hosted/convertx/app
  postBuild:
    substitute:
      APP: convertx
      KOPIUR_CAPACITY: 5Gi
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: self-hosted
  wait: false
```

- [ ] **Step 9.3: Commit**

```bash
git add kubernetes/apps/self-hosted/convertx/ks.yaml
git commit -m "feat(self-hosted): migrate convertx backup from volsync to kopiur

Pilot app for kopiur migration. The existing PVC is preserved (dataSourceRef
is immutable post-creation; Flux reports a cosmetic diff but does not
recreate the PVC). The Restore CR remains inert as long as the PVC exists.

Other apps still on volsync — generalization happens in a follow-up once
this pilot is validated."
```

### Task 10: Local validation + push branch + open PR 2

- [ ] **Step 10.1: Verify branch state**

```bash
git status
git log --oneline main..HEAD   # should show 1 commit on this branch
```

Expected: working tree clean, 1 commit ahead of `main`.

- [ ] **Step 10.2: Run flate tests (Kustomization)**

```bash
mise exec -- flate test ks --path ./kubernetes/apps/self-hosted/convertx
```

Expected: PASS.

- [ ] **Step 10.3: Diff against main**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```

Expected: only one changed resource (convertx Kustomization). The new CRs that kopiur renders (SnapshotPolicy, SnapshotSchedule, Restore) should appear as additions.

- [ ] **Step 10.4: Push branch + open PR**

```bash
git push -u origin HEAD

gh pr create \
  --title "feat(self-hosted): migrate convertx backup from volsync to kopiur" \
  --body "Pilot migration of convertx to validate kopiur end-to-end before generalizing to the 23 other apps.

## What
- \`components/volsync\` → \`components/kopiur/backup\`
- \`dependsOn volsync/volsync-system\` → \`dependsOn kopiur/kopiur-system\`
- \`VOLSYNC_CAPACITY: 5Gi\` → \`KOPIUR_CAPACITY: 5Gi\`

## Pre-merge prerequisites
- [x] PR #N (kopiur infra) merged
- [x] ClusterRepository \`nas\` Ready on the cluster
- [x] Final volsync snapshot of convertx captured (\`kubectl patch replicationsource convertx ...\`)
- [ ] (Optional) convertx scaled down to 0 during apply

## PVC preservation
The existing PVC \`convertx\` is preserved. \`spec.dataSourceRef\` is immutable post-creation; Flux reports a cosmetic diff on this field but does NOT recreate the PVC. Backup orchestration switches from volsync to kopiur; data stays intact.

## Post-merge validation checklist
1. \`flux get ks -n self-hosted convertx\` → Ready=True
2. \`kubectl -n self-hosted get snapshotpolicy,snapshotschedule,restore convertx\` → 3 CRs Ready
3. \`kubectl -n self-hosted get pvc convertx\` → still Bound, same capacity/age
4. Wait for next \`H * * * *\` slot OR trigger a manual \`Snapshot\`:
   \`kubectl -n self-hosted create -f <(cat <<EOF
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Snapshot
metadata:
  generateName: convertx-manual-
spec:
  policyRef:
    name: convertx
EOF
)\`
5. \`kubectl -n self-hosted get snapshots -w\` → Phase=Succeeded, status.stats.bytesNew > 0
6. \`find /volume1/Kopiur -name '*.f' | head\` on funkstation → blobs present
7. Kopia UI port-forward: snapshot visible under identity \`self-hosted-convertx@self-hosted\`

## volsync state
The \`ReplicationSource convertx\` and \`ReplicationDestination convertx-dst\` CRs are removed by Flux (prune) since they're no longer in the rendered manifest. Other apps continue to be backed up by volsync unchanged.

Refs: docs/superpowers/specs/2026-07-18-kopiur-migration-design.md" \
  --base main
```

- [ ] **Step 10.5: Post-merge validation**

After PR 2 merges, watch the cluster for 24h:
- `kubectl logs -n kopiur-system deploy/kopiur-controller` — no recurring errors
- `kubectl -n self-hosted get snapshots` — hourly snapshots appearing
- Kopia UI browsable
- After 24h: full retention cycle validated, ready for generalization (separate plan)

## Troubleshooting

If something fails on the cluster, here are the most likely issues:

| Symptom | Cause | Fix |
|---|---|---|
| `ClusterRepository/nas` stuck `Pending` or `Failed: permission denied` | NFS folder not writable by UID 1024 | SSH to funkstation: `chown -R 1024:100 /volume1/Kopiur && chmod 750 /volume1/Kopiur` |
| `ExternalSecret kopiur-repository` not synced | 1Password item `kopiur` missing or wrong vault | Verify item exists in vault pointed to by `ClusterSecretStore/onepassword`; check `kubectl describe externalsecret -n kopiur-system kopiur-repository` |
| Webhook pod stuck `ContainerCreating` | Normal for self-signed TLS mode — controller mints the cert on startup | Wait 30s; if still stuck: `kubectl logs -n kopiur-system deploy/kopiur-controller` |
| `SnapshotPolicy convertx` not Ready | ClusterRepository not Ready, or webhook rejected it | `kubectl describe snapshotpolicy -n self-hosted convertx` — see Conditions |
| PVC `convertx` re-created (data loss!) | Flux SSA conflict on `dataSourceRef` | DO NOT delete the PVC. Re-apply from main; the existing PVC must be preserved. If this happens, restore from the volsync snapshot taken in Task 8 |

## See also

- Design spec: `docs/superpowers/specs/2026-07-18-kopiur-migration-design.md`
- AGENTS.md: `Common Operations` section for flate/flux commands
- kopiur filesystem backend: https://github.com/home-operations/kopiur/blob/main/docs/backends/filesystem.md
- kopiur install guide: https://github.com/home-operations/kopiur/blob/main/docs/install.md
