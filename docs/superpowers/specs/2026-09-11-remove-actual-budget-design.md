# Design — Suppression de actual-budget et de ses snapshots kopiur

Date : 2026-09-11
Statut : approuvé (design présenté et validé par l'utilisateur)

## Contexte

- `actual` (actual-server) est déployé dans `kubernetes/apps/self-hosted/actual/` (ns `self-hosted`), HTTPRoute `actual.oxygn.dev`. L'utilisateur ne s'en sert plus.
- L'app est sauvegardée via le component `kubernetes/components/kopiur/backup` vers le `ClusterRepository/nas` (repo kopia sur NFS `funkstation.internal`), partagé avec ~24 autres apps.
- État cluster : 41 CRs `Snapshot actual-*` dans `self-hosted` (32 Succeeded + 9 Failed), tous `deletionPolicy: Delete`, `onScheduleDelete: Retain`.
- Point clé : le prune Flux ne supprime pas les données de snapshots kopia. Les CRs `Snapshot` survivent à la suppression de leur `SnapshotSchedule` (`onScheduleDelete: Retain`) ; leur suppression explicite déclenche un Job batch `snapdel-nas-*` créé par le controller kopiur, qui purge chaque snapshot du repo kopia puis retire le finalizer `kopiur.home-operations.com/snapshot-cleanup`.

## Approche retenue

**A — PR git + suppression explicite des CRs Snapshot** (approches rejetées : B suppression manuelle via UI kopia `kopia.oxygn.dev`, plus de manipulations sans traçabilité ; C PR git seulement, ne purge pas le repo).

## Changements

### 1. Git (branche + PR)

- Supprimer `kubernetes/apps/self-hosted/actual/` : `ks.yaml`, `app/kustomization.yaml`, `app/helmrelease.yaml`, `app/ocirepository.yaml`.
- Retirer la ligne `- ./actual/ks.yaml` de `kubernetes/apps/self-hosted/kustomization.yaml`.
- Aucune autre référence dans le repo (le record DNS `actual.oxygn.dev` est géré par external-dns depuis le HTTPRoute ; rien d'autre ne dépend de la Kustomization `actual`).
- Validation locale avant push : `flate test ks --path ./kubernetes/apps` et `flate diff` contre `origin/main` (worktree).

### 2. Effet du merge (prune Flux)

Retirés automatiquement : Kustomization `actual`, HelmRelease (Deployment, Service, HTTPRoute), OCIRepository, SnapshotPolicy `actual`, SnapshotSchedule `actual`, Restore `actual`, PVC `actual` (données de l'app — destruction assumée), PVC `kopiur-cache-actual`. Le record DNS est purgé par external-dns à la suppression du HTTPRoute.

Les CRs `Snapshot actual-*` restent en place (comportement attendu, cf. contexte).

### 3. Purge des snapshots (post-merge, cluster-side)

```bash
kubectl delete snapshots.kopiur.home-operations.com -n self-hosted \
  -l kopiur.home-operations.com/config=actual
```

Le controller crée les Jobs `snapdel-nas-*` (ns `kopiur-system`) qui suppriment chaque snapshot du repo kopia NFS, puis retirent les finalizers.

### 4. Ordre et sécurité

- La PR est ouverte pour revue utilisateur ; la purge cluster-side ne s'exécute qu'une fois le merge confirmé (par l'utilisateur ou par l'agent checks verts).
- Merge d'abord (le SnapshotSchedule supprimé arrête la création de nouveaux snapshots), purge ensuite : aucune fenêtre où un snapshot neuf serait créé pendant le nettoyage.
- Avant merge : rollback par revert de la PR. Après purge : irréversible (données app + snapshots détruites) — confirmé par l'utilisateur.
- Fallback si un `snapdel` échoue : suppression manuelle via l'UI kopia (lecture seule `false` déjà configurée) puis re-clean des finalizers.

## Vérification

- `flux get ks actual` introuvable ; Kustomization `self-hosted` Ready.
- Aucun CR `Snapshot actual-*` restant : `kubectl get snapshots -n self-hosted -l kopiur.home-operations.com/config=actual` vide.
- Logs du controller sans erreurs `snapdel` (`snapshot deleted by batch Job; finalizer removed`).
- Espace NFS récupéré après la maintenance full (cron `0 3 * * *`, tz Europe/Paris).
