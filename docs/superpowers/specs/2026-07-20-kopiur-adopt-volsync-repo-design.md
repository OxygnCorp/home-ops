# Design : Adoption du repo kopia volsync par kopiur

**Date** : 2026-07-20
**Statut** : Validé et éprouvé (migration pilote `convertx` réussie end-to-end)
**Auteur** : Puchu (agent IA)
**Scope** : Repointer le `ClusterRepository` kopiur existant vers le repo kopia du fork volsync (`/volume1/Volsync`) en mode adoption (`create.enabled: false`), et pinner l'identité dans le component `kopiur/backup` pour que les snapshots fork existants soient découverts et que l'historique kopia soit continu (dé-duplication). La bascule effective des ~22 apps volsync → kopiur se fera progressivement, app-par-app, dans des PRs ultérieures.

## Note importante sur la version kopiur 0.7.5

Les docs officielles (`docs/scenarios/adopt-existing-repo.md`, `docs/repositories.md`) décrivent une feature d'**auto-adoption** des snapshots discovered (`origin: discovered` → `origin: adopted` via `catalog.adoption: Adopt`). Cette feature **n'existe pas encore en kopiur 0.7.5** (notre version) : le champ `catalog.adoption` est absent du schéma CRD, ainsi que `SnapshotPolicy.spec.adoption`.

Le critère de succès d'une migration n'est donc pas l'adoption CR-side, mais **l'identity continuity kopia-side** : nouveaux snapshots écrits sous l'identité fork `<app>@<namespace>:/data`, déduplication automatique contre les snapshots fork existants. Les snapshots fork restent visibles comme `origin: discovered` et sont restorables via `Restore.source.identity`. Lors d'une future montée de version kopiur (≥ version qui ajoute `catalog.adoption`), les snapshots discovered seront auto-adoptés sans action de notre part.

## Contexte

Le cluster tourne deux operators de backup kopia côte-à-côte :

- **volsync** (fork `perfectra1n/volsync`) — ~22 apps via `components/volsync/`, repo kopia sur NFS `funkstation.internal:/volume1/Volsync`, password 1Password `volsync-template`. Un `KopiaMaintenance daily` (volsync-system) gère le repo.
- **kopiur** — déployé au dessus d'un repo séparé `funkstation.internal:/volume1/Kopiur` (`ClusterRepository/nas`, `create.enabled: true`). Une seule app (`convertx`) l'utilise, mais sa bascule n'a pas fonctionné : convertx reste en réalité backupé par volsync et a des snapshots disponibles dans `/volume1/Volsync`.

Objectif : **mutualiser** sur le repo volsync existant (`/volume1/Volsync`) pour que kopiur adopte l'historique volsync (`origin: discovered` → `origin: adopted`) sans re-upload, et que les bascules app-par-app soient transparentes.

## Procédure de référence

https://github.com/home-operations/kopiur/blob/main/docs/scenarios/adopt-existing-repo.md — Scenario 05. Le tip block recommande `kubectl kopiur migrate volsync` pour les repos du fork, qui est un port bug-for-bug du sanitizer d'identité (`crates/migrate/src/kopia.rs` ↔ `internal/controller/mover/kopia/builder.go` du fork). Ce design reproduit ce que le CLI calcule, en kustomize pur, dans le component réutilisable.

## Décisions arrêtées

| Décision | Choix | Raison |
|---|---|---|
| Backend ClusterRepository `nas` | Repointé vers `/volume1/Volsync` | Adopter le repo existant, pas en créer un nouveau |
| `create.enabled` | `false` | Adopt : ne jamais ré-initialiser le repo |
| `maintenance.enabled` | `false` pendant la cohabitation | Le fork `KopiaMaintenance daily` garde le lease ; on réactivera `Force` dans un dernier PR post-bascule complète pour éviter deux processes qui compactent en parallèle |
| Secret `KOPIA_PASSWORD` | ExternalSecret clé 1Password `kopiur` (inchangé) | Password aligné manuellement sur `volsync-template` ; la clé `kopiur` reste l'identité sémantique du secret kopiur |
| Compression | `zstd` (inchangé) | kopia decompress according per-snapshot metadata, pas policy globale ; pas de risque pour les snapshots fork (`zstd-fastest`) |
| Identité component | `username: ${APP}`, `sourcePathOverride: /data` | Match l'identité fork `<sanitized metadata.name>@<sanitized metadata.namespace>:/data` |
| Identité component : hostname | Non pinné (default kopiur `namespace`) | Le `hostnameExpr: "namespace"` du ClusterRepository match par défaut le hostname fork (sanitized namespace = namespace pour DNS-1123) |
| Ancien repo `/volume1/Kopiur` | Abandonné | Vide / inutilisé en pratique |
| `KopiaMaintenance daily` fork | Inchangé pendant la bascule | Garde le repo sain pendant que les apps migrent progressivement |

## Algorithme d'identité du fork volsync

Source vérifiée : `internal/controller/mover/kopia/builder.go` (fork) ↔ `crates/migrate/src/kopia.rs` (kopiur, port bug-for-bug).

- `username` ← `sanitizeForIdentifier(metadata.name, allowUnderscore=true, allowDots=false)` : keep `[a-zA-Z0-9_-]`, drop `.`, trim `-`/`_` bords, truncate 50 bytes sans re-trim, fallback `volsync-default`.
- `hostname` ← `sanitizeForIdentifier(metadata.namespace, allowUnderscore=false, allowDots=true)` : keep `[a-zA-Z0-9-.]`, `_` → `-`, trim `-`/`.` bords, pas de cap, fallback sanitized name puis `volsync-default`.
- `sourcePath` ← `spec.kopia.sourcePathOverride` verbatim si set, sinon `/data` (le `DATA_DIR` / `sourceMountPath` du mover fork).
- Identity string : `<username>@<hostname>:<sourcePath>`.

**Hypothèse validée pour ce repo** : tous les `metadata.name` et `metadata.namespace` des apps concernées sont DNS-1123 (`[a-z0-9-]`, pas de `_`, `.`, majuscules ou chars non-ASCII) — la sanitization est **identity**, donc l'identité fork équivaut à `<app>@<namespace>:/data`. Garanti par admission k8s. Le component kopiur pinné reproduit exactement cette chaîne.

## Changements de ce PR

### Fichier 1 — `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml`

| Champ | Avant | Après |
|---|---|---|
| `backend.filesystem.nfs.path` | `/volume1/Kopiur` | `/volume1/Volsync` |
| `create.enabled` | `true` | `false` |
| `maintenance.enabled` | `true` | `false` |

Reste inchangé : `encryption.passwordSecretRef` → `kopiur-repository-secret` (ExternalSecret clé `kopiur`), `catalog.periodicRefresh: true, refreshInterval: 1h` (garanti la découverte des snapshots fork pendant la bascule), `identityDefaults.hostnameExpr: "namespace"` (match hostname fork), `moverDefaults.securityContext` UID 1024 / GID 100 / fsGroup 100 (match fork mover), `takeoverPolicy: Force` (reste mais inerte tant que `maintenance.enabled: false`).

### Fichier 2 — `kubernetes/components/kopiur/backup/snapshotpolicy.yaml`

Deux champs ajoutés :

```yaml
spec:
  identity:
    username: ${APP}                      # pin volsync fork username
  ...
  sources:
    - pvc:
        name: ${APP}
      sourcePathOverride: /data           # pin volsync fork mount path
```

`identity.hostname` n'est pas pinné : kopiur default (namespace via `hostnameExpr`) match volsync hostname default, et préserve la flex (pas besoin d'exposer `${NAMESPACE}` en kustomize, qui n'est pas une var native). Le `identityDefaults.usernameExpr` (`namespace + '-' + policyName`) du ClusterRepository reste en place comme fallback pour un usage futur non pinné ; il est neutralisé par le pin `username: ${APP}` sur le component.

## Ce que ce PR ne touche PAS

- `apps/volsync-system/volsync/maintenance/kopiamaintenance.yaml` — inchangé, garde le repo sain.
- `components/volsync/*` — inchangé, apps restent sur volsync jusqu'à choix explicite.
- Les ~22 `ks.yaml` qui référencent `components/volsync` — aucun touché.
- ExternalSecret kopiur — inchangé (clé `kopiur`).
- Repo `/volume1/Kopiur` — abandonné (vide / inutilisé).

## Bascule progressive (procédure documentée, pas d'action dans ce PR)

Pour chaque app voulue, après merge de ce PR infra, **procédure éprouvée sur convertx** :

1. **`ks.yaml`** : remplacer `- ../../../../components/volsync` → `- ../../../../components/kopiur/backup`, ajuster `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY` (même unité), et `dependsOn: volsync/volsync-system` → `kopiur/kopiur-system`.
2. **Scale down** le workload pour éviter tout accès concurrent à la PVC :
   ```bash
   kubectl -n <ns> scale deploy <app> --replicas=0
   kubectl -n <ns> wait pod -l app.kubernetes.io/name=<app> --for=delete --timeout=60s
   ```
3. **Supprimer les CRs volsync** (suspend le fork pour cette app) :
   ```bash
   kubectl -n <ns> delete replicationsource <app>
   kubectl -n <ns> delete replicationdestination <app>-dst
   kubectl -n <ns> delete externalsecret <app>-volsync
   ```
4. **Supprimer la PVC data + cache** (la donnée est safe dans le repo kopia `/volume1/Volsync`) :
   ```bash
   kubectl -n <ns> delete pvc <app>                          # data PVC
   # la cache PVC volsync-src-<app>-cache est normalement auto-supprimée par volsync
   ```
5. **Force Flux reconcile** :
   ```bash
   flux reconcile kustomization <app> -n <ns> --with-source
   ```
   Flux crée : `SnapshotPolicy` (identity pinnée `${APP}@<ns>:/data`), `SnapshotSchedule`, `Restore` (avec `credentialProjection.enabled: true` → credentials projetés dans le ns), `PVC` (avec `dataSourceRef: Restore/<app>`).
6. **Attendre Restore Completed + PVC Bound** (kopiur résout automatiquement l'identity et restore le dernier snapshot kopia correspondant — pas besoin d'adoption CR-side en 0.7.5) :
   ```bash
   kubectl -n <ns> wait restore <app> --for=jsonpath='{.status.phase}'=Completed --timeout=10m
   kubectl -n <ns> wait pvc <app> --for=jsonpath='{.status.phase}'=Bound --timeout=2m
   ```
7. **Scale up** le workload :
   ```bash
   kubectl -n <ns> scale deploy <app> --replicas=1
   kubectl -n <ns> wait pod -l app.kubernetes.io/name=<app> --for=condition=ready --timeout=120s
   ```
8. **Valider** que le prochain snapshot schedule déduplique (history continuity) :
   ```bash
   # prochain cron H * * * * (dans <1h), ou trigger manuel via Snapshot create
   kubectl -n <ns> get snapshots -l kopiur.home-operations.com/config=<app> -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NEW_FILES:.status.stats.filesNew,NEW_BYTES:.status.stats.bytesNew
   # Succès : filesNew=N (fichiers modifiés depuis dernier fork), bytesNew vide ou petit (dé-dup)
   ```
9. **Dernier PR post-bascule complète (toutes les apps)** : réactiver `maintenance.enabled: true` sur le ClusterRepository `nas` + supprimer `KopiaMaintenance daily` fork + décommissionner l'install volsync.

Filet de sécurité : `kubectl kopiur migrate volsync -f ./kubernetes/apps/<ns>/<app> --repository nas --out-dir /tmp/migrated` peut être utilisé en mode offline GitOps pour vérifier que l'identité pinnée matche exactement ce que le CLI calcule.

## Validation post-deploy

```bash
# Le ClusterRepository adopte le repo existant
kubectl get clusterrepository nas -o jsonpath='phase={.status.phase} discovered={.status.catalog.discoveredBackupCount}{"\n"}'
# Attendu : phase=Ready, discovered=808+ (tous les snapshots fork materialisés)

# Snapshots fork visibles comme discovered (restorables via Restore.source.identity)
kubectl get snapshots -A -l kopiur.home-operations.com/origin=discovered

# convertx — pilote éprouvé (7+ snapshots schedule réussis sous identity fork)
kubectl -n self-hosted get snapshotpolicy convertx -o jsonpath='{.status.resolved.identity}{"\n"}'
# Attendu : {"hostname":"self-hosted","sourcePath":"/data","username":"convertx"}

kubectl -n self-hosted get snapshots -l kopiur.home-operations.com/config=convertx -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,FILES_NEW:.status.stats.filesNew
# Attendu : filesNew faible (3-5) sur le 1er schedule = dédup contre historique fork prouvée
```

## Risques

| Risque | Probabilité | Mitigation |
|---|---|---|
| Identité fork ≠ identité kopiur pinnée (fork historique) | Faible | Hypothèse DNS-1123 garantie par admission k8s ; `kubectl kopiur migrate volsync --strict` peut vérifier en offline |
| Deux processes maintenance en parallèle pendant bascule | Faible | `maintenance.enabled: false` côté kopiur, fork garde seul le lease |
| Snapshots fork non découverts | Faible | `catalog.periodicRefresh: true` sur le ClusterRepository ; `force-sync` annotation disponible |
| `usernameExpr` du ClusterRepository match pas fork | N/A | Neutralisé par le pin `identity.username: ${APP}` au niveau du component |
| Credentials Secret absent du ns du workload | Moyenne | `credentialProjection.enabled: true` sur policy + restore (gate à 3 parties : owner `allowed`, operator RBAC, consumer `enabled`) — les 3 sont en place après PR 2 |
| Race restore avant 1er snapshot | Faible | kopiur 0.7.5 résout automatiquement l'identity et restore le dernier snapshot kopia correspondant (observé sur convertx) — `onMissingSnapshot: Continue` ne reste pas vide en pratique |
| Adoption CR-side (origin discovered → adopted) | N/A en 0.7.5 | Feature non implémentée dans cette version. Les discovered rows restent mais sont restoreables via `Restore.source.identity`. L'identity continuity kopia-side est le critère de succès réel. |

## Historique de réalisation

| Commit | Date | Sujet |
|---|---|---|
| `13fd95803` | 2026-07-20 | `feat(kopiur): adopt existing volsync kopia repo` — repoint ClusterRepository + pin identity component |
| `4b45d8904` | 2026-07-20 | `feat(kopiur): opt consumer into credential projection` — gate consumer sur SnapshotPolicy + Restore |

## Pilote convertx — résultat éprouvé (2026-07-20, 12:24 UTC → 18:50 UTC)

- ✅ Migration end-to-end réussie (scale down → delete volsync CRs + PVC → Flux apply → Restore depuis kopia → scale up)
- ✅ Convertx Running 1/1, données préservées (jobId continue à 3044438)
- ✅ 7 snapshots schedule réussis sous identity `convertx@self-hosted:/data` (12:50, 13:50, 14:50, 15:50, 16:50, 17:50, 18:50 UTC)
- ✅ Premier snapshot post-migration : `filesNew=3, bytesNew=<empty>` — kopia a dédupliqué contre l'historique fork (aucun byte ré-uploadé)
- ⚠️ 37 discovered rows fork restent en `origin: discovered` (normal en 0.7.5, auto-adoption pas encore implémentée)