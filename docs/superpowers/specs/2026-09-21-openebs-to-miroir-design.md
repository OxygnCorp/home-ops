# Migration OpenEBS → Miroir

**Date** : 2026-09-21
**Statut** : approuvé (design)
**Prérequis** : PR #4533 (k8s-3 ajouté au pool miroir-slow) — mergée, pool visible sur k8s-3

## Contexte

Le cluster utilise OpenEBS uniquement pour son provisionneur `localpv-provisioner` (hostpath, SC `openebs-hostpath`) : pas de CSI, donc pas de snapshots kopiur possibles sur ces volumes. Miroir est déjà la classe par défaut (`miroir-slow`, répliqué ×2) et offre `miroir-slow-local` (1 réplica, node-local) au même profil que l'actuel openebs-hostpath, avec en plus le CSI miroir (snapshots) et le parity de tooling (kopiur, tuppr, debug miroir).

### État des lieux (relevé du 2026-09-21)

23 PVs bound sur `openebs-hostpath` :

| Usage | Volumes | Nature |
|---|---|---|
| CNPG Postgres : 6 clusters d'app × 3 instances (litellm, n8n, teslamate, authentik, forgejo, ghostfolio) | 18 × 5Gi | Critique, mais WAL archiving barman continu (R2) + annotations `bootstrap.recovery` en place |
| Runner GitHub Actions (work dirs) | 3 × 5Gi | Éphémère, re-provisionné par run |
| Caches modèles qwen3 (embedding + reranker) | 2 × 10Gi | Re-téléchargeables |

Manifests référençant `openebs-hostpath` :

- `kubernetes/components/postgres/cluster.yaml:28` — le composant partagé des 6 clusters vivants
- `kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml:16` — cluster `postgres` désactivé (commenté dans son ks.yaml), à basculer par cohérence
- `kubernetes/apps/actions-runner-system/actions-runner-controller/runners/home-ops/helmrelease.yaml:22`
- `kubernetes/apps/ai/llmkube/app/helmrelease.yaml:24` — PVC pas encore provisionné

Points d'attache OpenEBS hors manifests d'apps :

- `kubernetes/apps/openebs-system/` (HelmRelease, OCIRepository, ks, namespace)
- `kubernetes/apps/actions-runner-system/actions-runner-controller/ks.yaml` — `dependsOn: openebs`
- `talos/main/machineconfig.yaml.j2:74-78` — kubelet `extraMounts /var/openebs/local`
- `kubernetes/mod.just:45` — `reset-node` wipe `u-local-hostpath` (à vérifier : référence openebs uniquement)

## Décisions

1. **Profil de stockage** : tout passe en `miroir-slow-local` (1 réplica, node-local). La réplication Postgres reste à la charge de CNPG (sync replica `minSyncReplicas=1` + barman) ; empiler du DRBD synchrone sous CNPG doublerait la latence de commit sans gain (rebuild d'instance via pg_basebackup déjà rapide). Bonus : les volumes deviennent snapshotables kopiur.
2. **Méthode de migration des données CNPG** : rolling rebuild par instance (switchover → suppression PVC+pod → pg_basebackup depuis les instances saines). Downtime ≈ secondes, pas de dépendance à une restore R2 complète.
3. **Phasage** : Git-first en 2 vagues (PR cible → opération live → PR teardown).

## Design

### Vague 1 — PR Git « cible »

Changement de SC uniquement dans les 4 manifests listés ci-dessus (`openebs-hostpath` → `miroir-slow-local`). Aucun PVC existant n'est modifié (le SC n'est lu qu'à la création). Le SC `openebs-hostpath` reste déployé pendant toute l'opération (les PVs existants y réfèrent).

### Opération live — rolling rebuild CNPG

Ordre du moins critique au plus critique : `teslamate` → `ghostfolio` → `forgejo` → `authentik` → `n8n` → `litellm`.

Par cluster, via le plugin `kubectl cnpg` (v1.28) :

1. `kubectl cnpg switchover <cluster> -n <ns>` — bascule le primaire vers un réplica
2. `kubectl delete pvc <cluster>-1` + `kubectl delete pod <cluster>-1` — l'opérateur re-provisionne l'instance sur `miroir-slow-local` (nouveau PVC + pg_basebackup depuis le primaire courant)
3. Attente `kubectl cnpg status` vert, puis étape 2 sur l'instance suivante
4. Garde-fous entre chaque instance : cluster healthy, 3/3 ready, PVC vérifié sur le nouveau SC

### Recyclage des volumes éphémères

- Runners : suppression des 3 PVCs (re-provisionnés par le prochain run sur le nouveau SC)
- Caches qwen3 : suppression des 2 PVCs + pods ; re-téléchargement des modèles au redémarrage (~2-3 min)

### Vague 2 — PR Git « teardown » + apply Talos

1. Suppression de `kubernetes/apps/openebs-system/` → Flux prune la release, le SC et le namespace
2. Retrait du `dependsOn: openebs` dans `actions-runner-controller/ks.yaml`
3. Retrait du `extraMounts /var/openebs/local` dans `talos/main/machineconfig.yaml.j2` + `apply-node` sur les 4 nœuds
4. Nettoyage de `u-local-hostpath` dans `kubernetes/mod.just` si la vérification confirme qu'il ne concerne qu'OpenEBS

**Ordre strict** : la vague 2 n'est appliquée qu'après vérification zéro PV/PVC openebs et pods OpenEBS inutilisés.

## Risques & rollback

- **Rebuild bloqué** : l'instance reste dégradée, les 2 autres portent le service ; barman recovery = plan B ultime (annotations déjà en place)
- **Capacité pools** miroir : 130–310 GB libres par CP, volumes 5Gi — non bloquant
- **Rollback Git** : revert de la PR ; les PVCs déjà migrés restent sur Miroir (pas de retour auto, assumé)
- **Fenêtre de risque par cluster** : une instance en rebuild à la fois, jamais deux

## Hors scope

- Ajout de SnapshotSchedules kopiur sur les volumes CNPG (nouvelle capacité post-migration, décision séparée)
- Utilisation de k8s-3 pour des réplicas CNPG (les pools CP suffisent)
- Suppression du pool OpenEBS sur disque (`/var/openebs/local` reste un dossier vide sur les nœuds)

## Validation

- Par PR : `flate test ks/hr` + `flate diff` + konflate
- Par cluster rebuildé : `kubectl cnpg status` + `kubectl get pvc` (SC = `miroir-slow-local` ×3)
- Fin de migration : zéro PV/PVC `openebs-hostpath`, SC absente, `talosctl read /proc/mounts` sans `/var/openebs`, pods OpenEBS absents, `just talos render-config` sans extraMounts
