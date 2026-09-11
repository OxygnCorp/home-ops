# kopiur

Per-app PVC backup via [kopiur](https://github.com/home-operations/kopiur) — a volsync fork using Kopia as the mover backend. Replaced volsync on this cluster (see `docs/superpowers/plans/2026-07-18-kopiur-migration.md`). Backups land on a shared `ClusterRepository/nas` (Kopia filesystem backend over NFS at `funkstation.internal:/volume1/Volsync`, adopting the pre-existing volsync repository — `create.enabled: false`), operated by the kopiur controller in `kopiur-system`.

Two sub-components:

| Path              | Contents                                                                                                     |
|-------------------|--------------------------------------------------------------------------------------------------------------|
| `backup/`         | `SnapshotPolicy` (zstd, retention, mover security context), `SnapshotSchedule` (hourly), PVC + `Restore` populator |
| `secret/`         | `ExternalSecret` projecting the repository `KOPIA_PASSWORD` from 1Password into the namespace                |

Apps only reference `backup/`. The `secret/` sub-component is used **once**, by the `kopiur-system` app, to feed the `ClusterRepository`'s `passwordSecretRef` — per-app repository credentials are projected into workload namespaces automatically by the policy's `credentialProjection`.

## What gets created

Adding `components/kopiur/backup` to an app's Flux Kustomization creates, in the app namespace:

- **`SnapshotPolicy`** `${APP}` — zstd compression, mover `runAsUser/Group` `1024:100`, persistent cache PVC (`miroir-slow`), staging PVC (`miroir-slow-local`), `volumeSnapshotClassName: miroir`, retention `keepLatest: 3 / keepHourly: 24 / keepDaily: 7 / keepWeekly: 4`, source PVC `${APP}` mounted at `/data`.
- **`SnapshotSchedule`** `${APP}` — hourly (`H * * * *`), referencing the policy.
- **`PVC`** `${APP}` — created from the `Restore` via `dataSourceRef`, so a net-new namespace is populated from the latest snapshot (`onMissingSnapshot: Continue` lets a brand-new app start empty).
- **`Restore`** `${APP}` — volume populator tied to the policy (`offset: 0` = latest snapshot).

## Substitution variables

| Variable                       | Default            | Notes                                                     |
|--------------------------------|--------------------|-----------------------------------------------------------|
| `APP`                          | _(required)_       | Name of the app and of the source PVC.                    |
| `KOPIUR_PUID` / `KOPIUR_PGID`  | `1024` / `100`     | Mover ownership, matches NFS ownership.                   |
| `KOPIUR_CAPACITY`              | `5Gi`              | Size of the app PVC and of the persistent cache PVC.      |
| `KOPIUR_ACCESSMODES`           | `ReadWriteOnce`    | Access mode of the app PVC.                               |
| `KOPIUR_STORAGECLASS`          | `miroir-slow`      | StorageClass of the app PVC.                              |
| `KOPIUR_CACHE_STORAGECLASS`    | `miroir-slow`      | Cache PVC StorageClass (must be replicated — see below).  |
| `KOPIUR_STAGING_STORAGECLASS`  | `miroir-slow-local`| Staging PVC StorageClass (must be unreplicated).          |
| `KOPIUR_SNAPSHOTCLASS`         | `miroir`           | VolumeSnapshotClass used for backups.                     |
| `KOPIUR_REPOSITORY`            | `nas`              | Target `ClusterRepository`.                               |

## Design notes

- **Cache replicated, staging local.** The cache PVC uses a replicated class: a local cache would pin the mover to one node and conflict with the staging PVC's node affinity (unschedulable movers). Conversely, staging is deliberately unreplicated: replicating it means a full sync (plus tie-breaker) of data that is deleted minutes later.
- **Identity and mount path are pinned** (`username: ${APP}`, `sourcePathOverride: /data`) to keep volsync-fork semantics instead of kopiur defaults (`<namespace>-<app>` identity, `/pvc/<name>` path).
- **Restores are declarative.** Because the PVC is populated from the `Restore` CR, deleting the PVC + app and letting Flux reconcile restores the latest snapshot automatically.

## Usage

```yaml
spec:
  components:
    - ../../../../components/zeroscaler
    - ../../../../components/kopiur/backup
  dependsOn:
    - name: kopiur
      namespace: kopiur-system
```
