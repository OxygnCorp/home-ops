# Remove actual-budget + kopiur snapshots — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Supprimer l'app `actual` (actual-budget) du repo GitOps et purger ses 41 snapshots du repo kopia `nas`.

**Architecture:** PR git (suppression du répertoire app + ligne dans la kustomization parent) → merge → prune Flux retire toutes les ressources k8s (y compris SnapshotPolicy/Schedule/Restore/PVCs). Ensuite suppression explicite des CRs `Snapshot actual-*` (le prune ne les touche pas : `onScheduleDelete: Retain`), ce qui déclenche les Jobs batch `snapdel-nas-*` du controller kopiur qui purgent le repo kopia NFS.

**Tech Stack:** Flux (Kustomization, prune), kustomize components (`kopiur/backup`), kopiur CRDs (`snapshots.kopiur.home-operations.com`), `flate` (validation locale), `gh` (PR).

**Spec:** `docs/superpowers/specs/2026-09-11-remove-actual-budget-design.md`

## Global Constraints

- **Workdir : tout se passe dans le worktree `/tmp/opencode/remove-actual`** (branche `remove-actual-budget`, basée sur `origin/main`). Ne JAMAIS travailler depuis le worktree principal (WIP utilisateur sur `fix/opencode-gatus-ignore-redirect`).
- Commits conventionnels (`chore(self-hosted): ...`), pas de `--no-verify` ni skip de hooks.
- `flate` s'invoque via `mise exec -- flate ...`.
- Ne jamais rebaser/forcer ; push simple `git push -u origin remove-actual-budget`.
- La purge cluster-side (Task 2) est **irréversible** : uniquement après merge confirmé de la PR.

---

### Task 1: Suppression Git de l'app + validation flate + PR

**Files:**
- Delete: `kubernetes/apps/self-hosted/actual/ks.yaml`
- Delete: `kubernetes/apps/self-hosted/actual/app/kustomization.yaml`
- Delete: `kubernetes/apps/self-hosted/actual/app/helmrelease.yaml`
- Delete: `kubernetes/apps/self-hosted/actual/app/ocirepository.yaml`
- Modify: `kubernetes/apps/self-hosted/kustomization.yaml:11` (ligne `- ./actual/ks.yaml`)

**Interfaces:**
- Consumes: worktree existant `/tmp/opencode/remove-actual` avec le commit spec `5d389a93e`.
- Produces: PR ouverte depuis `remove-actual-budget` vers `main`, prête à merger. Task 2 dépend du merge de cette PR.

- [ ] **Step 1: Supprimer le répertoire de l'app**

```bash
git -C /tmp/opencode/remove-actual rm -r kubernetes/apps/self-hosted/actual
```
Expected: `rm 'kubernetes/apps/self-hosted/actual/...'` × 4 fichiers.

- [ ] **Step 2: Retirer la référence de la kustomization parent**

Dans `/tmp/opencode/remove-actual/kubernetes/apps/self-hosted/kustomization.yaml`, supprimer la ligne `- ./actual/ks.yaml`. Résultat attendu de la section resources :

```yaml
resources:
  - ./namespace.yaml
  # - ./nextcloud/ks.yaml
  - ./convertx/ks.yaml
  - ./ghostfolio/ks.yaml
  - ./mealie/ks.yaml
  - ./omni-tools/ks.yaml
  - ./stirling-pdf/ks.yaml
  - ./webhook/ks.yaml
```

Vérifier qu'il ne reste AUCUNE référence à `actual` dans le repo :

```bash
grep -rn "self-hosted/actual\|actual\.oxygn\.dev" /tmp/opencode/remove-actual/kubernetes /tmp/opencode/remove-actual/talos 2>/dev/null || echo "CLEAN"
```
Expected: `CLEAN`

- [ ] **Step 3: Valider avec flate (test)**

```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps
```
(les deux depuis `/tmp/opencode/remove-actual`)
Expected: succès sur tous les clusters, 0 erreur.

- [ ] **Step 4: Valider avec flate (diff contre origin/main)**

```bash
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
```

Baseline (préalable, depuis `/tmp/opencode/remove-actual`) :

```bash
git worktree add --detach /tmp/baseline origin/main
```

Expected: uniquement des SUPPRESSIONS sous `kubernetes/apps/self-hosted/actual/` (ks `actual`, HR `actual` et ressources rendues : Deployment/Service/HTTPRoute, OCIRepository, SnapshotPolicy/SnapshotSchedule/Restore, PVC `actual` + `kopiur-cache-actual`). Si le diff contient AUTRE CHOSE que des suppressions dans ce périmètre : STOP et investiguer.

Cleanup baseline :

```bash
git worktree remove /tmp/baseline --force
```

- [ ] **Step 5: Commit**

```bash
git -C /tmp/opencode/remove-actual add -A
git -C /tmp/opencode/remove-actual commit -m "chore(self-hosted): remove actual-budget"
```
Expected: commit créé, 5 fichiers touchés (4 deletions + kustomization.yaml).

- [ ] **Step 6: Push + ouvrir la PR**

```bash
git -C /tmp/opencode/remove-actual push -u origin remove-actual-budget
```

Écrire le body ci-dessous dans `/tmp/opencode/remove-actual/.pr-body.md` puis :

```bash
gh pr create --title "chore(self-hosted): remove actual-budget" --body-file /tmp/opencode/remove-actual/.pr-body.md
rm /tmp/opencode/remove-actual/.pr-body.md
```

Body de PR :

```markdown
Suppression de actual-budget (inutilisé) et purge de ses snapshots kopiur.

## Changements Git
- Delete `kubernetes/apps/self-hosted/actual/`
- Retrait de `- ./actual/ks.yaml` de `kubernetes/apps/self-hosted/kustomization.yaml`

## Effet au merge (prune)
HR/Deployment/Service/HTTPRoute `actual.oxygn.dev`, OCIRepository, SnapshotPolicy/Schedule/Restore, PVC `actual` (données app — destruction assumée) + PVC cache kopiur.

## Post-merge (manuel, hors Git)
Suppression des 41 CRs `Snapshot actual-*` (le prune ne les gère pas : `onScheduleDelete: Retain`) → Jobs `snapdel-nas-*` → purge du repo kopia `nas`. Voir spec: `docs/superpowers/specs/2026-09-11-remove-actual-budget-design.md`.
```

Expected: URL de PR retournée. Attendre les checks CI verts (konflate en particulier). **Demander confirmation à l'utilisateur avant de merger.** Merger puis Task 2.

---

### Task 2: Purge des snapshots kopiur (post-merge, cluster-side)

**Files:** aucun (opérations cluster uniquement).

**Interfaces:**
- Consumes: PR Task 1 mergée + Flux reconcilié (prune effectif).
- Produces: 0 CR `Snapshot actual-*` restant, repo kopia `nas` purgé des snapshots actual, espace NFS récupéré au prochain maintenance full (03:00).

- [ ] **Step 1: Vérifier que le prune est effectif**

```bash
flux reconcile source git flux-system
flux reconcile kustomization self-hosted
flux get ks actual 2>&1
kubectl get helmrelease,httproute,pvc -n self-hosted 2>&1 | grep -i actual || echo "PRUNED"
kubectl get snapshotpolicy,snapshotschedule,restore -n self-hosted 2>&1 | grep -i actual || echo "PRUNED"
```
Expected: `flux get ks actual` → NotFound ; `PRUNED` pour le reste. Les CRs `Snapshot actual-*` doivent être les SEULS restants :

```bash
kubectl get snapshots.kopiur.home-operations.com -n self-hosted -l kopiur.home-operations.com/config=actual --no-headers | wc -l
```
Expected: `41` (ou proche — les nouvelles créations ont cessé au merge).

- [ ] **Step 2: Supprimer les CRs Snapshot de actual**

```bash
kubectl delete snapshots.kopiur.home-operations.com -n self-hosted -l kopiur.home-operations.com/config=actual
```
Expected: `snapshot.kopiur.home-operations.com "actual-..." deleted` × N. La commande peut prendre du temps (finalizer `snapshot-cleanup` retiré par le controller après purge kopia effective).

- [ ] **Step 3: Vérifier la purge**

```bash
kubectl get snapshots.kopiur.home-operations.com -n self-hosted -l kopiur.home-operations.com/config=actual 2>&1
kubectl logs -n kopiur-system deploy/kopiur-controller --since=15m 2>&1 | grep -iE 'actual' | grep -ciE 'snapshot deleted by batch Job; finalizer removed'
kubectl get jobs -n kopiur-system 2>&1 | grep -c snapdel || true
```
Expected: `No resources found` ; N lignes `snapshot deleted by batch Job` sans erreur ; jobs `snapdel` Completed. En cas d'échec d'un job : inspecter `kubectl logs job/<name> -n kopiur-system`, fallback = suppression via UI kopia (`kopia.oxygn.dev`, lecture seule désactivée) puis re-clean des finalizers.

- [ ] **Step 4: Clôturer**

- Vérifier la Kustomization parent : `flux get ks self-hosted` → Ready/True.
- (Optionnel, lendemain) Espace NFS récupéré après maintenance full 03:00 : `kubectl logs -n kopiur-system -l app.kubernetes.io/name=nas-kopia-ui --since=12h | grep -i maintenance`.
- Nettoyage local : `git worktree remove /tmp/opencode/remove-actual` (après merge) + `git branch -d remove-actual-budget`.
