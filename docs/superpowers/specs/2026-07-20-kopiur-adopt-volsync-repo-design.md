# Design : Adoption du repo kopia volsync par kopiur

**Date** : 2026-07-20
**Statut** : Validé (design approuvé), en cours d'implémentation
**Auteur** : Puchu (agent IA)
**Scope** : Repointer le `ClusterRepository` kopiur existant vers le repo kopia du fork volsync (`/volume1/Volsync`) en mode adoption (`create.enabled: false`), et pinner l'identité dans le component `kopiur/backup` pour que les snapshots fork existants soient découverts et adoptés automatiquement. La bascule effective des ~22 apps volsync → kopiur se fera progressivement, app-par-app, dans des PRs ultérieures.

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

Pour chaque app voulue, après merge de ce PR infra :

1. `ks.yaml` : remplacer `- ../../../../components/volsync` → `- ../../../../components/kopiur/backup`, ajuster `VOLSYNC_CAPACITY` → `KOPIUR_CAPACITY` (même unité), et `dependsOn: volsync/volsync-system` → `kopiur/kopiur-system`.
2. `kubectl -n <ns> delete replicationsource <app>` (suspend le fork ; garder le Secret volsync — kopiur le référence in place pour le password via l'ExternalSecret clé `kopiur`, qui pointe le même 1Password vault item).
3. `flux reconcile kustomization <app> -n flux-system` → kopiur crée la `SnapshotPolicy` (identité pinnée `${APP}@<namespace>:/data`) → découvre snapshots fork (`origin: discovered`) → adopte automatiquement (`origin: adopted`).
4. Dernier PR post-bascule complète : réactiver `maintenance.enabled: true` sur le ClusterRepository `nas` + supprimer `KopiaMaintenance daily` fork + décommissionner l'install volsync.

Filet de sécurité : `kubectl kopiur migrate volsync -f ./kubernetes/apps/<ns>/<app> --repository nas --out-dir /tmp/migrated` peut être utilisé en mode offline GitOps pour vérifier que l'identité pinnée matche exactement ce que le CLI calcule.

## Validation post-deploy

```bash
# Le ClusterRepository adopte le repo existant
kubectl get repository nas -n kopiur-system                                   # Ready

# Les snapshots fork apparaissent comme discovered
kubectl get snapshots -A -l kopiur.home-operations.com/origin=discovered      # rows pour les apps fork

# convertx — premier cas test automatique (son ks.yaml référence déjà components/kopiur/backup)
kubectl -n self-hosted get snapshotpolicy convertx -o jsonpath='{.spec.identity}{"\n"}'
# Attendu : {"username":"convertx"} (hostname résolu = self-hosted via hostnameExpr)
kubectl -n self-hosted get snapshots -l kopiur.home-operations.com/origin=discovered
# Attendu : rows pour convertx (snapshots fork découverts)
flux reconcile kustomization convertx -n self-hosted
# Dernier snapshot nouveau liste sous la même identité que les discovered (continuité d'historique)
```

## Risques

| Risque | Probabilité | Mitigation |
|---|---|---|
| Identité fork ≠ identité kopiur pinnée (fork historique) | Faible | Hypothèse DNS-1123 garantie par admission k8s ; `kubectl kopiur migrate volsync --strict` peut vérifier en offline |
| Deux processes maintenance en parallèle pendant bascule | Faible | `maintenance.enabled: false` côté kopiur, fork garde seul le lease |
| Snapshots fork non découverts | Faible | `catalog.periodicRefresh: true` sur le ClusterRepository ; `force-sync` annotation disponible |
| `usernameExpr` du ClusterRepository match pas fork | N/A | Neutralisé par le pin `identity.username: ${APP}` au niveau du component |