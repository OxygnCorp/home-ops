# Miroir Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Rook/Ceph with Miroir (DRBD9 + LVM thin) as the cluster's replicated block storage, migrating all PVCs via a planned maintenance window.

**Architecture:** Miroir controller + agent DaemonSet deployed in a privileged `miroir-system` namespace. LVM thin backend on partition `r-miroir-slow` (created via Talos `RawVolumeConfig`) on the 3 control-plane nodes. DRBD9 replicas:2 with `quorum: freeze` over InternalIP. The 23 kopiur-backed apps restore from kopia repository; the ~6 non-kopiur apps start fresh. k8s-3 remains client-only.

**Tech Stack:** Miroir chart 0.11.11 (`oci://ghcr.io/home-operations/charts/miroir`), Talos 1.13.5 with `siderolabs/drbd` extension, Flux GitOps, kustomize components, kopiur restore.

## Global Constraints

These apply to every task implicitly; copy values verbatim, do not invent:

- **miroir chart version**: `0.11.11` (latest at 2026-07-24 on `oci://ghcr.io/home-operations/charts/miroir`)
- **miroir chart OCI URL**: `oci://ghcr.io/home-operations/charts/miroir`
- **StorageClass names**: `miroir-slow` (default, replicas:2) and `miroir-slow-local` (replicas:1)
- **VolumeSnapshotClass name**: `miroir`
- **Pool name**: `slow`
- **Partition label**: `r-miroir-slow` (created by Talos `RawVolumeConfig`, accessible at `/dev/disk/by-partlabel/r-miroir-slow`)
- **MiroirNodeGroup name**: `default`
- **Namespace**: `miroir-system` (privileged: `pod-security.kubernetes.io/enforce=privileged`)
- **DRBD quorum policy**: `freeze`
- **DRBD replica count**: `2` (controller `replicaCount: 2`, storage class `replicas: "2"`)
- **DRBD alExtents**: `6007`
- **autoEvictAfter**: `1h`
- **kernel modules to add**: `dm_thin_pool`, `drbd` (with `usermode_helper=disabled`), `drbd_transport_tcp`
- **kubelet shutdownGracePeriod**: `90s`
- **kubelet shutdownGracePeriodCriticalPods**: `60s`
- **Talos version**: `v1.13.5` (already deployed; meets miroir >= 1.13.0 requirement)
- **Grafana matchLabel**: `dashboards: grafana` (verified against existing dashboards)
- **kopiur StorageClass default**: `miroir-slow` (replaces `ceph-block`)
- **kopiur VolumeSnapshotClass default**: `miroir` (replaces `csi-ceph-blockpool`)
- **Flatten tool**: `mise exec -- flate ...` (see AGENTS.md)
- **Flux root path**: `./kubernetes/apps` (Flux discovers all `kustomization.yaml` recursively via `kubernetes/flux/cluster/ks.yaml`)

## Prerequisites (manual, before starting)

- [ ] **Feature branch created**: `git checkout -b feat/miroir-migration`
- [ ] **Disk identification**: Run `talosctl -n k8s-0 disks` (and k8s-1, k8s-2) to identify the Ceph data disk model/transport/WWN. Record the exact disk selector criteria for `RawVolumeConfig`. The disk must NOT be the system disk.
- [ ] **Maintenance window scheduled**: All stateful workloads will be down for ~1-2h during Phase C.

---

## Phase A: GitOps Preparation (feature branch)

All changes in this phase go on branch `feat/miroir-migration`. The branch is NOT merged until Phase C (maintenance window).

### Task A1: Create miroir-system namespace and kustomization

**Files:**
- Create: `kubernetes/apps/miroir-system/namespace.yaml`
- Create: `kubernetes/apps/miroir-system/kustomization.yaml`

- [ ] **Step 1: Create the namespace**

Create `kubernetes/apps/miroir-system/namespace.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: miroir-system
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

- [ ] **Step 2: Create the kustomization**

Create `kubernetes/apps/miroir-system/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: miroir-system
resources:
  - ./namespace.yaml
  - ./miroir/ks.yaml
```

### Task A2: Create miroir HelmRelease and OCIRepository

**Files:**
- Create: `kubernetes/apps/miroir-system/miroir/app/kustomization.yaml`
- Create: `kubernetes/apps/miroir-system/miroir/app/ocirepository.yaml`
- Create: `kubernetes/apps/miroir-system/miroir/app/helmrelease.yaml`

- [ ] **Step 1: Create app kustomization**

Create `kubernetes/apps/miroir-system/miroir/app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
```

- [ ] **Step 2: Create OCIRepository**

Create `kubernetes/apps/miroir-system/miroir/app/ocirepository.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: miroir
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.11.11
  url: oci://ghcr.io/home-operations/charts/miroir
```

- [ ] **Step 3: Create HelmRelease**

Create `kubernetes/apps/miroir-system/miroir/app/helmrelease.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: miroir
spec:
  chartRef:
    kind: OCIRepository
    name: miroir
  interval: 1h
  values:
    autoEvictAfter: 1h
    drbd:
      alExtents: 6007
    groupSnapshots:
      enabled: true
    monitoring:
      dashboards:
        enabled: true
        grafanaOperator:
          enabled: true
          matchLabels:
            dashboards: grafana
      podMonitor:
        enabled: true
      prometheusRule:
        enabled: true
    replicaCount: 2
```

### Task A3: Create miroir config (topology, StorageClasses, VolumeSnapshotClass)

**Files:**
- Create: `kubernetes/apps/miroir-system/miroir/config/kustomization.yaml`
- Create: `kubernetes/apps/miroir-system/miroir/config/miroirnodegroup.yaml`
- Create: `kubernetes/apps/miroir-system/miroir/config/storageclass.yaml`
- Create: `kubernetes/apps/miroir-system/miroir/config/volumesnapshotclass.yaml`

- [ ] **Step 1: Create config kustomization**

Create `kubernetes/apps/miroir-system/miroir/config/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./miroirnodegroup.yaml
  - ./storageclass.yaml
  - ./volumesnapshotclass.yaml
```

- [ ] **Step 2: Create MiroirNodeGroup**

Create `kubernetes/apps/miroir-system/miroir/config/miroirnodegroup.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/miroir.home-operations.com/miroirnodegroup_v1alpha1.json
apiVersion: miroir.home-operations.com/v1alpha1
kind: MiroirNodeGroup
metadata:
  name: default
spec:
  nodeSelector:
    matchLabels:
      node-role.kubernetes.io/control-plane: ""
  template:
    pools:
      - name: slow
        lvmthin:
          device: /dev/disk/by-partlabel/r-miroir-slow
```

- [ ] **Step 3: Create StorageClasses**

Create `kubernetes/apps/miroir-system/miroir/config/storageclass.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/storage.k8s.io/storageclass_v1.json
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: miroir-slow-local
provisioner: miroir.home-operations.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  miroir.home-operations.com/pool: slow
  miroir.home-operations.com/replicas: "1"
  csi.storage.k8s.io/fstype: ext4
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/storage.k8s.io/storageclass_v1.json
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: miroir-slow
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: miroir.home-operations.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
parameters:
  miroir.home-operations.com/pool: slow
  miroir.home-operations.com/replicas: "2"
  miroir.home-operations.com/quorum: freeze
  csi.storage.k8s.io/fstype: ext4
```

- [ ] **Step 4: Create VolumeSnapshotClass**

Create `kubernetes/apps/miroir-system/miroir/config/volumesnapshotclass.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/snapshot.storage.k8s.io/volumesnapshotclass_v1.json
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: miroir
driver: miroir.home-operations.com
deletionPolicy: Delete
```

### Task A4: Create Flux Kustomization (ks.yaml)

**Files:**
- Create: `kubernetes/apps/miroir-system/miroir/ks.yaml`

- [ ] **Step 1: Create ks.yaml with two Flux Kustomizations**

Create `kubernetes/apps/miroir-system/miroir/ks.yaml`:

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: miroir
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: miroir
  dependsOn:
    - name: snapshot-controller
      namespace: kube-system
  interval: 1h
  path: ./kubernetes/apps/miroir-system/miroir/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: miroir-system
  wait: true
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: miroir-config
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: miroir
  dependsOn:
    - name: miroir
  interval: 1h
  path: ./kubernetes/apps/miroir-system/miroir/config
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: miroir-system
  wait: true
```

- [ ] **Step 2: Validate with flate**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/miroir-system
```

Expected: all checks pass, no errors.

- [ ] **Step 3: Commit Phase A scaffolding**

```bash
git add kubernetes/apps/miroir-system/
git commit -m "feat(miroir): add miroir-system app scaffolding"
```

### Task A5: Update kopiur component defaults

**Files:**
- Modify: `kubernetes/components/kopiur/backup/pvc.yaml:16`
- Modify: `kubernetes/components/kopiur/backup/snapshotpolicy.yaml:37`

- [ ] **Step 1: Update PVC default StorageClass**

In `kubernetes/components/kopiur/backup/pvc.yaml`, change line 16:

```yaml
# Before:
  storageClassName: ${KOPIUR_STORAGECLASS:=ceph-block}
# After:
  storageClassName: ${KOPIUR_STORAGECLASS:=miroir-slow}
```

- [ ] **Step 2: Update SnapshotPolicy default VolumeSnapshotClass**

In `kubernetes/components/kopiur/backup/snapshotpolicy.yaml`, change line 37:

```yaml
# Before:
  volumeSnapshotClassName: ${KOPIUR_SNAPSHOTCLASS:=csi-ceph-blockpool}
# After:
  volumeSnapshotClassName: ${KOPIUR_SNAPSHOTCLASS:=miroir}
```

- [ ] **Step 3: Validate**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
```

Expected: all checks pass.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/components/kopiur/backup/
git commit -m "feat(kopiur): switch defaults to miroir-slow / miroir"
```

### Task A6: Update app Flux Kustomization dependencies (22 apps)

Each of these 22 apps has `dependsOn: [{name: rook-ceph-cluster, namespace: rook-ceph}]` in their `ks.yaml`. Replace with `dependsOn: [{name: miroir-config, namespace: miroir-system}]`.

**Files to modify (all `ks.yaml`):**
1. `kubernetes/apps/ai/devclaw/ks.yaml`
2. `kubernetes/apps/ai/lightrag/ks.yaml`
3. `kubernetes/apps/ai/mainclaw/ks.yaml`
4. `kubernetes/apps/automation/home-assistant/ks.yaml`
5. `kubernetes/apps/automation/mosquitto/ks.yaml`
6. `kubernetes/apps/download/prowlarr/ks.yaml`
7. `kubernetes/apps/download/qbittorrent/ks.yaml`
8. `kubernetes/apps/download/qui/ks.yaml`
9. `kubernetes/apps/download/radarr/ks.yaml`
10. `kubernetes/apps/download/sabnzbd/ks.yaml`
11. `kubernetes/apps/download/sonarr/ks.yaml`
12. `kubernetes/apps/media/agregarr/ks.yaml`
13. `kubernetes/apps/media/audiobookshelf/ks.yaml`
14. `kubernetes/apps/media/komga/ks.yaml`
15. `kubernetes/apps/media/plex/ks.yaml`
16. `kubernetes/apps/media/seerr/ks.yaml`
17. `kubernetes/apps/media/tautulli/ks.yaml`
18. `kubernetes/apps/observability/grafana/ks.yaml`
19. `kubernetes/apps/observability/kube-prometheus-stack/ks.yaml`
20. `kubernetes/apps/observability/victoria-logs/ks.yaml`
21. `kubernetes/apps/self-hosted/convertx/ks.yaml`
22. `kubernetes/apps/self-hosted/stirling-pdf/ks.yaml`

- [ ] **Step 1: Update all 22 ks.yaml files**

For each file, replace:

```yaml
# Before:
  dependsOn:
    - name: rook-ceph-cluster
      namespace: rook-ceph
# After:
  dependsOn:
    - name: miroir-config
      namespace: miroir-system
```

Use this command to verify all replacements were made:

```bash
rg "rook-ceph-cluster" kubernetes/apps/ -g "ks.yaml" | grep -v "rook-ceph/"
```

Expected: no output (all references removed from non-rook-ceph apps).

- [ ] **Step 2: Validate**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
```

Expected: all checks pass.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/
git commit -m "feat(apps): switch dependsOn from rook-ceph-cluster to miroir-config"
```

### Task A7: Update explicit StorageClass references (6 apps)

These apps reference `ceph-block` explicitly in their HelmRelease or PVC manifests.

**Files to modify:**
1. `kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml` (lines 34, 122)
2. `kubernetes/apps/observability/grafana/instance/grafana.yaml` (line 79)
3. `kubernetes/apps/observability/victoria-logs/app/helmrelease.yaml` (line 24)
4. `kubernetes/apps/observability/gatus-sidecar/app/helmrelease.yaml` (line 49)
5. `kubernetes/apps/automation/home-assistant/app/pvc.yaml` (line 11)
6. `kubernetes/apps/automation/mosquitto/app/helmrelease.yaml` (line 36)

- [ ] **Step 1: Replace all ceph-block references**

For each file, replace `storageClassName: ceph-block` with `storageClassName: miroir-slow` (or `storageClass: ceph-block` with `storageClass: miroir-slow` for mosquitto's app-template syntax).

Verify no `ceph-block` references remain outside of `rook-ceph/`:

```bash
rg "ceph-block" kubernetes/apps/ -g "*.yaml" | grep -v "rook-ceph/"
```

Expected: no output.

- [ ] **Step 2: Validate**

```bash
mise exec -- flate test hr --path ./kubernetes/apps
```

Expected: all checks pass.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/
git commit -m "feat(apps): switch StorageClass from ceph-block to miroir-slow"
```

### Task A8: Remove rook-ceph directory

**Files:**
- Delete: `kubernetes/apps/rook-ceph/` (entire directory)

- [ ] **Step 1: Delete the rook-ceph directory**

```bash
git rm -r kubernetes/apps/rook-ceph/
```

- [ ] **Step 2: Verify no dangling references**

```bash
rg "rook-ceph" kubernetes/ -g "*.yaml" | grep -v "flux-system/"
```

Expected: no output (or only references in the branch being merged, which are the dependency changes already done).

- [ ] **Step 3: Validate**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps
```

Expected: all checks pass.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(rook-ceph): remove rook-ceph in favor of miroir"
```

- [ ] **Step 5: Push the feature branch**

```bash
git push -u origin feat/miroir-migration
```

---

## Phase B: Talos Preparation

This phase is executed directly on the nodes (not via Flux). It prepares the kernel modules and graceful shutdown BEFORE the maintenance window. The `RawVolumeConfig` is NOT applied yet (it would conflict with active Ceph OSDs).

### Task B1: Update Talos schematic

**Files:**
- Modify: `talos/main/controlplane/schematic.yaml`

- [ ] **Step 1: Add siderolabs/drbd extension**

In `talos/main/controlplane/schematic.yaml`, add the DRBD extension:

```yaml
---
customization:
  extraKernelArgs:
    - intel_iommu=on # PCI Passthrough
    - iommu=pt # PCI Passthrough
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent # Proxmox
      - siderolabs/drbd # Miroir DRBD9 Replication
```

Note: `talos/main/worker/schematic.yaml` stays unchanged (k8s-3 is client-only, DRBD not needed).

- [ ] **Step 2: Compute the new schematic ID**

```bash
just talos schematic-id
```

Record the output — this is the new schematic ID for the control-plane nodes.

- [ ] **Step 3: Commit**

```bash
git add talos/main/controlplane/schematic.yaml
git commit -m "feat(talos): add siderolabs/drbd extension for miroir"
```

### Task B2: Update Talos machineconfig

**Files:**
- Modify: `talos/main/machineconfig.yaml.j2`

- [ ] **Step 1: Add kernel modules**

In `talos/main/machineconfig.yaml.j2`, update the `kernel.modules` section (currently only has `nbd`):

```yaml
  kernel:
    modules:
      - name: nbd
      - name: dm_thin_pool
      - name: drbd
        parameters:
          - usermode_helper=disabled
      - name: drbd_transport_tcp
```

- [ ] **Step 2: Add kubelet graceful shutdown**

In the same file, update `kubelet.extraConfig`:

```yaml
  kubelet:
    defaultRuntimeSeccompProfileEnabled: true
    disableManifestsDirectory: true
    extraConfig:
      serializeImagePulls: false
      shutdownGracePeriod: 90s
      shutdownGracePeriodCriticalPods: 60s
```

- [ ] **Step 3: Add RawVolumeConfig (document at end of file)**

Add a new YAML document at the end of `talos/main/machineconfig.yaml.j2`. Replace the `diskSelector.match` with the actual disk criteria identified in Prerequisites:

```yaml
---
apiVersion: v1alpha1
kind: RawVolumeConfig
name: miroir-slow
provisioning:
  diskSelector:
    match: disk.transport == "virtio" && !system_disk
  minSize: 1TB
```

> **CRITICAL**: The `diskSelector.match` must target the Ceph data disk specifically and MUST include `!system_disk` to never select the Talos OS disk. Verify with `talosctl -n <node> disks` before applying. The selector above is a placeholder — adjust to match your actual disk layout (e.g., by `disk.model`, `disk.serial`, `disk.wwid`, or `disk.size`).

- [ ] **Step 4: Commit**

```bash
git add talos/main/machineconfig.yaml.j2
git commit -m "feat(talos): add DRBD modules, graceful shutdown, RawVolumeConfig for miroir"
git push
```

### Task B3: Upgrade Talos nodes (sequential reboots)

This task applies the new Talos config to each control-plane node sequentially. Each node reboot causes brief pod rescheduling but no data loss (Ceph still has 3 OSDs).

- [ ] **Step 1: Verify disk selector on k8s-0**

Before applying, verify the `RawVolumeConfig` disk selector matches the right disk:

```bash
talosctl -n k8s-0 disks
```

Confirm the Ceph data disk matches the selector and the OS disk does NOT match (it has `system_disk` flag).

> **WARNING**: If the `RawVolumeConfig` would select the OS disk, DO NOT proceed. Fix the selector first.

- [ ] **Step 2: Apply config and reboot k8s-0**

```bash
just talos apply-node k8s-0
just talos reboot-node k8s-0
```

Wait for k8s-0 to be `Ready`:
```bash
kubectl wait node k8s-0 --for condition=Ready --timeout=10m
```

Wait for all pods to reschedule:
```bash
kubectl get pods -A --field-selector spec.nodeName=k8s-0 | grep -v Running | grep -v Completed
```

- [ ] **Step 3: Verify modules loaded on k8s-0**

```bash
talosctl -n k8s-0 lsmod | grep -E 'drbd|dm_thin_pool'
```

Expected: `drbd`, `drbd_transport_tcp`, `dm_thin_pool` all listed.

- [ ] **Step 4: Repeat for k8s-1**

```bash
just talos apply-node k8s-1
just talos reboot-node k8s-1
kubectl wait node k8s-1 --for condition=Ready --timeout=10m
talosctl -n k8s-1 lsmod | grep -E 'drbd|dm_thin_pool'
```

- [ ] **Step 5: Repeat for k8s-2**

```bash
just talos apply-node k8s-2
just talos reboot-node k8s-2
kubectl wait node k8s-2 --for condition=Ready --timeout=10m
talosctl -n k8s-2 lsmod | grep -E 'drbd|dm_thin_pool'
```

- [ ] **Step 6: Verify RawVolumeConfig partition was NOT created**

At this point, Ceph is still active on `/dev/sdb`. The `RawVolumeConfig` should have been skipped or deferred because the disk is in use by Ceph. Verify:

```bash
talosctl -n k8s-0 ls /dev/disk/by-partlabel/ | grep miroir
```

If the partition does NOT exist yet: correct (it will be created after Ceph removal in Phase C).
If the partition EXISTS on the Ceph disk: STOP — this means the selector matched the wrong disk or Ceph's BlueStore was overwritten. Investigate before proceeding.

> **Note**: Talos `RawVolumeConfig` will create the partition when the disk becomes available (after Ceph releases it). If Ceph is using the disk as a raw block device (BlueStore), Talos may not be able to create the partition until Ceph is removed. This is expected and safe.

---

## Phase C: Migration Execution (Maintenance Window)

**This is the destructive phase. All stateful workloads will be down.**

Estimated downtime: 1-2 hours.

### Task C1: Trigger fresh kopiur backups (J-1, before maintenance window)

- [ ] **Step 1: Force fresh snapshots for all 23 kopiur apps**

```bash
# Force sync all snapshot policies
kubectl get snapshotpolicy -A -o name | while read sp; do
  ns=$(echo "$sp" | cut -d/ -f1)
  name=$(echo "$sp" | cut -d/ -f2)
  kubectl annotate snapshotpolicy "$name" -n "$ns" force-sync=$(date +%s) --overwrite
done
```

- [ ] **Step 2: Verify all snapshots completed**

```bash
kubectl get snapshotpolicy -A -o wide
```

Check that each policy shows a recent `lastSnapshot` timestamp.

- [ ] **Step 3: Verify kopia repository integrity**

Access the kopia UI (via kopiur repository httproute) or run:

```bash
kubectl exec -n kopiur-system deploy/kopiur -- kopia repository verify
```

Expected: verification passes.

### Task C2: Scale down all workloads

- [ ] **Step 1: Suspend Flux reconciliation**

```bash
flux suspend kustomization cluster-apps -n flux-system
```

- [ ] **Step 2: Scale down all deployments and statefulsets**

```bash
kubectl scale deployment -A --replicas=0 --all
kubectl scale statefulset -A --replicas=0 --all
```

- [ ] **Step 3: Verify all pods are terminated**

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Wait until no pods are in `Terminating` state.

### Task C3: Delete PVCs and PVs

- [ ] **Step 1: Delete all ceph-block PVCs**

```bash
kubectl get pvc -A -o json | \
  jq -r '.items[] | select(.spec.storageClassName=="ceph-block") | "-n \(.metadata.namespace) \(.metadata.name)"' | \
  xargs -r kubectl delete pvc
```

- [ ] **Step 2: Delete orphaned PVs (Ceph RBD)**

```bash
kubectl get pv -o json | \
  jq -r '.items[] | select(.spec.csi.driver=="rook-ceph.rbd.csi.ceph.com" or .spec.csi.driver=="rook-ceph.cephfs.csi.ceph.com") | .metadata.name' | \
  xargs -r kubectl delete pv
```

- [ ] **Step 3: Verify no PVCs or PVs remain**

```bash
kubectl get pvc -A
kubectl get pv
```

Expected: no Ceph-backed PVCs or PVs listed.

### Task C4: Remove Rook/Ceph

- [ ] **Step 1: Delete CephCluster HelmRelease**

```bash
kubectl delete helmrelease rook-ceph-cluster -n rook-ceph
```

Wait for the CephCluster to be fully deleted (OSDs stop, MONs stop):

```bash
kubectl -n rook-ceph get cephcluster --watch
```

- [ ] **Step 2: Delete Ceph CSI drivers HelmRelease**

```bash
kubectl delete helmrelease ceph-csi-drivers -n rook-ceph
```

- [ ] **Step 3: Delete Rook operator HelmRelease**

```bash
kubectl delete helmrelease rook-ceph -n rook-ceph
```

- [ ] **Step 4: Delete rook-ceph namespace and CRDs**

```bash
kubectl delete namespace rook-ceph --wait=true
kubectl delete crd \
  cephclusters.ceph.rook.io \
  cephblockpools.ceph.rook.io \
  cephfilesystems.ceph.rook.io \
  cephobjectstores.ceph.rook.io \
  cephobjectstoreusers.ceph.rook.io \
  cephnfs.ceph.rook.io \
  cephclients.ceph.rook.io \
  cephrbdmirrors.ceph.rook.io \
  cephfilesystemmirrors.ceph.rook.io \
  cephbucketnotifications.ceph.rook.io \
  cephbuckettopics.ceph.rook.io \
  cephfilesystemsubvolumegroups.ceph.rook.io \
  --ignore-not-found=true
```

- [ ] **Step 5: Verify rook-ceph is fully removed**

```bash
kubectl get pods -n rook-ceph 2>&1
kubectl get crd | grep ceph
```

Expected: namespace not found, no Ceph CRDs.

### Task C5: Wipe Ceph disks

For each node, wipe the BlueStore header from the data disk so LVM/talos can use it.

- [ ] **Step 1: Wipe disk on k8s-0**

```bash
talosctl -n k8s-0 wipe disk /dev/sdb --mode fast
```

> If `talosctl wipe disk` is not available in this version, use a privileged pod:
> ```bash
> cat <<'EOF' | kubectl apply -f -
> apiVersion: v1
> kind: Pod
> metadata:
>   name: disk-wipe-k8s-0
>   namespace: default
> spec:
>   nodeName: k8s-0
>   restartPolicy: Never
>   containers:
>     - name: wipe
>       image: alpine:3.20
>       command: ["/bin/sh", "-c"]
>       args:
>         - |
>           apk add --no-cache sgdisk &&
>           sgdisk --zap-all /dev/sdb &&
>           dd if=/dev/zero of=/dev/sdb bs=1M count=100 oflag=direct
>       securityContext:
>         privileged: true
>       volumeMounts:
>         - name: dev
>           mountPath: /dev
>   volumes:
>     - name: dev
>       hostPath:
>         path: /dev
> EOF
> kubectl wait pod disk-wipe-k8s-0 --for condition=Ready --timeout=2m
> kubectl wait pod disk-wipe-k8s-0 --for jsonpath='{.status.phase}'=Succeeded --timeout=5m
> kubectl delete pod disk-wipe-k8s-0
> ```

- [ ] **Step 2: Wipe disk on k8s-1**

Same as Step 1, replacing `k8s-0` with `k8s-1`.

- [ ] **Step 3: Wipe disk on k8s-2**

Same as Step 1, replacing `k8s-0` with `k8s-2`.

### Task C6: Create partition via RawVolumeConfig

Now that the Ceph disks are wiped, re-apply the Talos config to trigger `RawVolumeConfig` partition creation.

- [ ] **Step 1: Re-apply Talos config on all CP nodes**

```bash
just talos apply-node k8s-0
just talos apply-node k8s-1
just talos apply-node k8s-2
```

- [ ] **Step 2: Verify partition exists**

```bash
talosctl -n k8s-0 ls /dev/disk/by-partlabel/
talosctl -n k8s-1 ls /dev/disk/by-partlabel/
talosctl -n k8s-2 ls /dev/disk/by-partlabel/
```

Expected: `r-miroir-slow` listed on each node.

> If the partition is not created, a node reboot may be needed for Talos to process the `RawVolumeConfig`:
> ```bash
> just talos reboot-node k8s-0
> just talos reboot-node k8s-1
> just talos reboot-node k8s-2
> ```

### Task C7: Merge GitOps branch and resume Flux

- [ ] **Step 1: Merge the feature branch to main**

```bash
git checkout main
git merge feat/miroir-migration
git push origin main
```

Alternatively, create a PR and merge via GitHub:

```bash
gh pr create --title "feat: replace rook-ceph with miroir" --body "Miroir migration: DRBD9 + LVM thin replacing Rook/Ceph" --base main --head feat/miroir-migration
```

- [ ] **Step 2: Resume Flux reconciliation**

```bash
flux resume kustomization cluster-apps -n flux-system
```

- [ ] **Step 3: Monitor Flux reconciliation**

```bash
flux get kustomizations -A
flux logs -f --kind=Kustomization --name=miroir -n miroir-system
```

Flux deploys in order:
1. `miroir` HelmRelease (controller Deployment + agent DaemonSet)
2. `miroir-config` (MiroirNodeGroup → agents provision LVM thin pools on `r-miroir-slow` partition)
3. Apps start deploying → PVCs created on `miroir-slow` → kopiur Restore populates volumes from kopia

- [ ] **Step 4: Verify miroir topology**

```bash
kubectl get miroirnodes
kubectl get miroirvolumes -A
```

Expected: 3 MiroirNodes (k8s-0, k8s-1, k8s-2) with pool `slow`, all `UpToDate`.

### Task C8: Wait for volume restoration

- [ ] **Step 1: Monitor PVC binding**

```bash
kubectl get pvc -A --watch
```

Expected: PVCs transition from `Pending` to `Bound` as miroir provisions them.

- [ ] **Step 2: Monitor kopiur Restore progress**

```bash
kubectl get restore -A --watch
```

Expected: Restore objects progress through phases until volumes are populated.

- [ ] **Step 3: Verify all pods are Running**

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Expected: no output (all pods running) or only expected non-running pods.

- [ ] **Step 4: Check DRBD replication status**

```bash
kubectl get miroirvolumes -A -o wide
```

Expected: volumes show 2 `UpToDate` legs + 1 diskless tie-breaker.

---

## Phase D: Post-Migration Validation

### Task D1: Verify app functionality

- [ ] **Step 1: Check critical apps**

```bash
kubectl get pods -n automation
kubectl get pods -n download
kubectl get pods -n media
kubectl get pods -n observability
kubectl get pods -n self-hosted
kubectl get pods -n ai
```

Each app should be `Running`.

- [ ] **Step 2: Spot-check data integrity**

- Home Assistant: verify UI accessible and recent state present
- Plex: verify library loaded
- Grafana: verify dashboards visible (regenerated from Git)
- Prometheus: verify metrics being scraped (fresh start)

### Task D2: Verify kopiur backup cycle

- [ ] **Step 1: Trigger a test backup with new VolumeSnapshotClass**

```bash
kubectl annotate snapshotpolicy home-assistant -n automation force-sync=$(date +%s) --overwrite
```

- [ ] **Step 2: Verify snapshot completes**

```bash
kubectl get snapshotpolicy home-assistant -n automation -o wide
```

Expected: new snapshot taken using `miroir` VolumeSnapshotClass.

### Task D3: Optional cleanup

- [ ] **Step 1: Remove obsolete net1 config (optional)**

If the `169.254.255.x` storage network is no longer used by anything (Ceph is gone), remove the `net1` LinkConfig from each per-node config:

- `talos/main/controlplane/k8s-0.yaml` — remove the `net1` LinkAliasConfig + LinkConfig documents
- `talos/main/controlplane/k8s-1.yaml` — same
- `talos/main/controlplane/k8s-2.yaml` — same

This is optional and can be done in a later maintenance window.

- [ ] **Step 2: Delete the feature branch**

```bash
git branch -d feat/miroir-migration
git push origin --delete feat/miroir-migration
```

- [ ] **Step 3: Update AGENTS.md (optional)**

Update the storage references in `AGENTS.md`:
- Change "Storage: Rook/Ceph + volsync" to "Storage: Miroir (DRBD9) + kopiur"
- Update the Component Reference table
- Remove Ceph-specific troubleshooting entries

---

## Rollback Procedure

### If miroir fails to install or volumes don't bind

**Scenario**: miroir controller won't start, or PVCs stuck in `Pending`.

1. Change the kopiur component default to `openebs-hostpath` (temporary fallback):

```yaml
# kubernetes/components/kopiur/backup/pvc.yaml
  storageClassName: ${KOPIUR_STORAGECLASS:=openebs-hostpath}
```

2. Push the change:

```bash
git add kubernetes/components/kopiur/backup/pvc.yaml
git commit -m "fix: fallback to openebs-hostpath for kopiur restore"
git push
```

3. Delete stuck PVCs:

```bash
kubectl get pvc -A -o json | \
  jq -r '.items[] | select(.status.phase=="Pending") | "-n \(.metadata.namespace) \(.metadata.name)"' | \
  xargs -r kubectl delete pvc
```

4. Flux recreates PVCs on `openebs-hostpath` → kopiur restores data → apps come back online on non-replicated local storage.

5. Diagnose miroir issue, fix, and re-migrate in a subsequent maintenance window.

### If data loss is discovered for a kopiur-backed app

The kopia repository on NFS has the backup. Restore manually:

```bash
kubectl exec -n kopiur-system deploy/kopiur -- kopia snapshot list
# Find the snapshot for the affected app
# Use kopia restore or create a Restore CR pointing to the specific snapshot
```
