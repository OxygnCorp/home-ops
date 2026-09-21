# Migration OpenEBS → Miroir — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer OpenEBS (localpv-provisioner hostpath) par Miroir `miroir-slow-local` sur tout le cluster, puis supprimer OpenEBS complètement.

**Architecture:** Git-first en 2 vagues — Vague 1 : PR basculant les 4 manifests vers `miroir-slow-local` (aucun PVC existant touché) ; opération live : rolling rebuild des 6 clusters CNPG + recyclage des volumes éphémères ; Vague 2 : PR teardown (OpenEBS, dépendances, extraMounts Talos). Spec : `docs/superpowers/specs/2026-09-21-openebs-to-miroir-design.md`.

**Tech Stack:** Flux (HelmRelease/Kustomization), CloudNativePG + plugin `kubectl cnpg` v1.28, Miroir CSI, Talos (apply-config), kustomize, flate.

## Global Constraints

- Worktree dédié `../home-ops-openebs-miroir`, branche `feat/openebs-to-miroir` (existe déjà, contient le commit spec `f2cd1deb2`)
- `TALOSCONFIG` : le talosconfig du worktree est une copie vide au clone — utiliser `export TALOSCONFIG=/home/nea0d/git/home-ops/talosconfig` si besoin hors recettes `just`
- Ne jamais committer de secrets ; secrets via 1Password + ExternalSecret
- Validation avant push : `mise exec -- flate test hr --base origin/main` (mode changed-only) + `mise exec -- flate diff hr --base origin/main`
- Les recettes `just` qui mutent l'état demandent une confirmation interactive (`<<< "y"` en batch)
- SC cible : `miroir-slow-local` (1 réplica, node-local, WaitForFirstConsumer, ext4). JAMAIS `miroir-slow` (répliqué ×2) pour CNPG dans ce plan
- Un seul PVC CNPG en rebuild à la fois, jamais deux
- Ordre des clusters CNPG (du moins au plus critique) : teslamate, ghostfolio, forgejo, authentik, n8n, litellm
- Inventaire des 6 clusters : `litellm` (ns `ai`), `n8n` (ns `ai`), `teslamate` (ns `automation`), `authentik` (ns `security`), `forgejo` (ns `self-hosted`), `ghostfolio` (ns `self-hosted`)

---

### Task 1: Vague 1 — PR bascule des StorageClasses

**Files:**
- Modify: `kubernetes/components/postgres/cluster.yaml:28`
- Modify: `kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml:16`
- Modify: `kubernetes/apps/actions-runner-system/actions-runner-controller/runners/home-ops/helmrelease.yaml:22`
- Modify: `kubernetes/apps/ai/llmkube/app/helmrelease.yaml:24`

**Interfaces:**
- Produces: tous les nouveaux PVCs CNPG/runner/llmkube provisionnés sur `miroir-slow-local` ; les PVCs existants restent sur `openebs-hostpath` (SC encore déployée)

- [ ] **Step 1: Basculer le composant postgres**

Dans `kubernetes/components/postgres/cluster.yaml`, remplacer :

```yaml
  storage:
    storageClass: openebs-hostpath
    size: 5Gi
```

par :

```yaml
  storage:
    storageClass: miroir-slow-local
    size: 5Gi
```

- [ ] **Step 2: Basculer le cluster postgres désactivé**

Dans `kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml`, remplacer :

```yaml
  storage:
    size: 15Gi
    storageClass: openebs-hostpath
```

par :

```yaml
  storage:
    size: 15Gi
    storageClass: miroir-slow-local
```

- [ ] **Step 3: Basculer les runners ARC**

Dans `kubernetes/apps/actions-runner-system/actions-runner-controller/runners/home-ops/helmrelease.yaml`, remplacer :

```yaml
      kubernetesModeWorkVolumeClaim:
        accessModes: ["ReadWriteOnce"]
        storageClassName: openebs-hostpath
```

par :

```yaml
      kubernetesModeWorkVolumeClaim:
        accessModes: ["ReadWriteOnce"]
        storageClassName: miroir-slow-local
```

- [ ] **Step 4: Basculer llmkube**

Dans `kubernetes/apps/ai/llmkube/app/helmrelease.yaml`, remplacer :

```yaml
    modelCache:
      enabled: true
      mode: perService
      size: 10Gi
      storageClass: openebs-hostpath
```

par :

```yaml
    modelCache:
      enabled: true
      mode: perService
      size: 10Gi
      storageClass: miroir-slow-local
```

- [ ] **Step 5: Vérifier qu'aucune référence openebs-hostpath ne subsiste hors openebs-system et hors cluster.yaml du composant déjà traité**

Run: `rg -n "openebs-hostpath" kubernetes/ | grep -v openebs-system`
Expected: sortie vide (le composant postgres et les 3 apps sont corrigés)

- [ ] **Step 6: Validation flate (changed-only contre origin/main)**

Run: `mise exec -- flate test hr --base origin/main && mise exec -- flate diff hr --base origin/main`
Expected: PASS sur les HR modifiées ; le diff ne montre que le changement de storageClass

- [ ] **Step 7: Commit + push + PR**

```bash
git add kubernetes/components/postgres/cluster.yaml \
  kubernetes/apps/database/cloudnative-pg/cluster/cluster.yaml \
  kubernetes/apps/actions-runner-system/actions-runner-controller/runners/home-ops/helmrelease.yaml \
  kubernetes/apps/ai/llmkube/app/helmrelease.yaml
git commit -m "feat(storage): switch openebs-hostpath to miroir-slow-local"
git push
gh pr create --title "feat(storage): switch openebs-hostpath to miroir-slow-local" --body "Wave 1 of openebs->miroir migration. See spec docs/superpowers/specs/2026-09-21-openebs-to-miroir-design.md. No existing PVC is touched (SC read at PVC creation only)."
```

Expected: URL de PR retournée ; attendre merge (konflate + review).

### Task 2: Merge + vérification post-Flux

**Files:** none (opération cluster)

**Interfaces:**
- Consomme: Task 1 mergée (Flux a réconcilié)
- Produces: état où tout nouveau PVC est provisionné sur `miroir-slow-local` — prérequis de Task 3/4

- [ ] **Step 1: Attendre la réconciliation Flux**

Run: `just kube sync && sleep 30 && kubectl get hr -A | grep -E "llmkube|home-ops-runner|cloudnative-pg"`
Expected: toutes les HR `True`

- [ ] **Step 2: Vérifier que les PVCs existants sont intacts**

Run: `kubectl get pv -o json | jq -r '[.items[] | select(.spec.storageClassName=="openebs-hostpath")] | "\(length) PVs openebs" '`
Expected: `23 PVs openebs` (aucun PV n'a bougé)

- [ ] **Step 3: Vérifier le SC cible disponible**

Run: `kubectl get sc miroir-slow-local -o jsonpath='{.provisioner}{"\n"}'`
Expected: `miroir.home-operations.com`

### Task 3: Opération live — rolling rebuild des 6 clusters CNPG

**Files:** none (opération cluster, via `kubectl cnpg`)

**Interfaces:**
- Consomme: Task 2 (nouveaux PVCs → `miroir-slow-local`)
- Produces: 18 PVCs CNPG sur `miroir-slow-local`, zéro sur openebs

Procédure par cluster — répéter exactement pour chacun dans l'ordre : **teslamate (automation) → ghostfolio (self-hosted) → forgejo (self-hosted) → authentik (security) → n8n (ai) → litellm (ai)**. Substituer `<cluster>` et `<ns>` par les valeurs de chaque ligne. Ne passer au cluster suivant que si tous les checks sont verts.

- [ ] **Step 1: Identifier le primaire**

Run: `kubectl cnpg status <cluster> -n <ns> | grep -E "Primary|Instances status" -A4`
Expected: ligne `Primary server: <cluster>-N` — noter N (ex. `teslamate-2`)

- [ ] **Step 2: Switchover vers un réplica**

Run: `kubectl cnpg switchover <cluster> <cluster>-{1,2,3 ≠ N} -n <ns>`
Expected: sortie `switchover process started` ; attends quelques secondes

- [ ] **Step 3: Vérifier le switchover**

Run: `kubectl cnpg status <cluster> -n <ns> | grep "Primary server"`
Expected: le nouveau primaire est l'instance choisie ; `Cluster in healthy state` ; 3/3 ready. Si dégradé : STOP, investiguer (`kubectl get events -n <ns> --sort-by=.lastTimestamp`) avant de continuer

- [ ] **Step 4: Rebuild de l'ancien primaire (PVC + pod)**

Run:
```bash
kubectl delete pvc <cluster>-N -n <ns>
kubectl delete pod <cluster>-N -n <ns>
```
Expected: l'opérateur recrée le pod avec un PVC neuf sur `miroir-slow-local` et le ré-synchronise via pg_basebackup depuis le primaire. Surveiller : `kubectl get pods -n <ns> -w | grep <cluster>-N` puis `kubectl cnpg status <cluster> -n <ns>`
Expected final: `Cluster in healthy state`, 3/3 ready, instance rebuildée en réplica synchronisé

- [ ] **Step 5: Vérifier le SC du PVC reconstruit**

Run: `kubectl get pvc <cluster>-N -n <ns> -o jsonpath='{.spec.storageClassName}{"\n"}'`
Expected: `miroir-slow-local`

- [ ] **Step 6: Rebuild du réplica restant (PVC + pod)**

Reprendre Step 4-5 avec le dernier `<cluster>-M` (le seul encore sur openebs). Mêmes checks.
Expected final: `Cluster in healthy state`, 3/3 ready

- [ ] **Step 7: Bilan du cluster**

Run: `kubectl get pvc -n <ns> -o json | jq -r '.items[] | select(.metadata.name | startswith("<cluster>-")) | [.metadata.name, .spec.storageClassName] | @tsv'`
Expected: 3 lignes, toutes `miroir-slow-local`. Passer au cluster suivant uniquement ici.

### Task 4: Recyclage des volumes éphémères (runners + caches qwen)

**Files:** none (opération cluster)

**Interfaces:**
- Consomme: Task 2 (nouvelles créations → `miroir-slow-local`)
- Produces: zéro PVC openebs restant dans le cluster

- [ ] **Step 1: Supprimer les PVCs runners (re-provisionnés par le prochain run)**

Run: `kubectl delete pvc -n actions-runner-system home-ops-runner-bwcmf-runner-hsqnr-work home-ops-runner-bwcmf-runner-smkgd-work home-ops-runner-bwcmf-runner-wkmkq-work`
Expected: `persistentvolumeclaim "..." deleted` ×3. Les PVCs du prochain run utiliseront `miroir-slow-local` (HR mergée en Task 1)

- [ ] **Step 2: Supprimer les PVCs + pods de cache qwen3 (re-téléchargement au démarrage)**

Run:
```bash
kubectl get pods -n ai | grep qwen3   # noter les noms des pods model-cache
kubectl delete pvc -n ai qwen3-embedding-0.6b-model-cache qwen3-reranker-0.6b-model-cache
kubectl delete pod -n ai <pod-qwen3-embedding> <pod-qwen3-reranker>
```
Expected: le contrôleur llmkube recrée PVC + pod ; les modèles se re-téléchargent (~2-3 min). Surveiller `kubectl get pvc -n ai | grep qwen3`

- [ ] **Step 3: Vérifier zéro PVC openebs restant**

Run: `kubectl get pvc -A -o json | jq -r '[.items[] | select(.spec.storageClassName=="openebs-hostpath")] | length'`
Expected: `0`

- [ ] **Step 4: Vérifier zéro PV openebs restant**

Run: `kubectl get pv -o json | jq -r '[.items[] | select(.spec.storageClassName=="openebs-hostpath")] | length'`
Expected: `0` (reclaimPolicy Delete → disparus avec les PVCs)

### Task 5: Vague 2 — PR teardown OpenEBS + Talos

**Files:**
- Delete: `kubernetes/apps/openebs-system/` (récursif : kustomization.yaml, namespace.yaml, openebs/ks.yaml, openebs/app/{helmrelease,kustomization,ocirepository}.yaml)
- Modify: `kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml:20-22` (retrait dependsOn)
- Modify: `kubernetes/apps/actions-runner-system/actions-runner-controller/ks.yaml:24-27` (retrait dependsOn)
- Modify: `talos/main/machineconfig.yaml.j2:74-78` (retrait extraMounts)
- Modify: `talos/mod.just:45` (retrait wipe u-local-hostpath)

**Interfaces:**
- Consomme: Task 4 (zéro PVC/PV openebs)
- Produces: OpenEBS désinstallé, SC `openebs-hostpath` supprimée, config Talos sans extraMounts

- [ ] **Step 1: Retirer le dependsOn openebs du HelmRelease cloudnative-pg**

Dans `kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml`, supprimer :

```yaml
  dependsOn:
    - name: openebs
      namespace: openebs-system
```

- [ ] **Step 2: Retirer le dependsOn openebs du Kustomization runners**

Dans `kubernetes/apps/actions-runner-system/actions-runner-controller/ks.yaml`, supprimer :

```yaml
    - name: openebs
      namespace: openebs-system
```

(le bloc `dependsOn:` conserve `- name: actions-runner-controller`)

- [ ] **Step 3: Retirer les extraMounts Talos**

Dans `talos/main/machineconfig.yaml.j2`, supprimer :

```yaml
    extraMounts:
      - destination: /var/openebs/local
        type: bind
        source: /var/openebs/local
        options: ["bind", "rshared", "rw"]
```

- [ ] **Step 4: Retirer le wipe u-local-hostpath de reset-node**

Dans `talos/mod.just:45`, remplacer :

```just
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe u-local-hostpath --graceful=false {{ args }}
```

par :

```just
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }}
```

- [ ] **Step 5: Supprimer le répertoire openebs-system**

Run: `git rm -r kubernetes/apps/openebs-system/`
Expected: 6 fichiers supprimés

- [ ] **Step 6: Vérifier l'isolation du render-config**

Run: `mise exec -- just talos render-config k8s-0 | grep -c "openebs"`
Expected: `0`. Puis diff complet contre origin/main : `mise exec -- just talos render-config k8s-3 | grep -c "openebs"` → `0`

- [ ] **Step 7: Validation flate + commit + PR**

Run:
```bash
mise exec -- flate test ks --base origin/main && mise exec -- flate test hr --base origin/main
rg -n "openebs" kubernetes/ | grep -v "docs/"
```
Expected: PASS ; la seule référence restante dans kubernetes/ est potentielle (aucune). Puis :

```bash
git add kubernetes/apps/openebs-system/ \
  kubernetes/apps/database/cloudnative-pg/app/helmrelease.yaml \
  kubernetes/apps/actions-runner-system/actions-runner-controller/ks.yaml \
  talos/main/machineconfig.yaml.j2 \
  talos/mod.just
git commit -m "feat(storage): remove openebs, fully migrated to miroir" && git push
gh pr create --title "feat(storage): remove openebs, fully migrated to miroir" --body "Wave 2: openebs-system removal, dependsOn cleanup, Talos extraMounts removal. Prereq: zero openebs PV/PVC verified live."
```

Expected: PR retournée ; **attendre merge AVANT le Step 8** (Flux prunera openebs-system : HR, OCIRepository, SC, namespace)

- [ ] **Step 8: Vérifier le prune Flux + appliquer les nœuds**

Run: `just kube sync && kubectl get ns openebs-system 2>&1 | grep -c NotFound; kubectl get sc openebs-hostpath 2>&1 | grep -c NotFound`
Expected: `1` et `1` (tous deux NotFound)

Puis, pour chaque nœud k8s-0, k8s-1, k8s-2, k8s-3 :
```bash
mise exec -- just talos apply-node <node> --dry-run
```
Expected: le diff montre uniquement le retrait des extraMounts (plus une normalisation éventuelle). Puis apply (confirmation interactive) :
```bash
mise exec -- just talos apply-node <node> <<< "y"
```
Expected: `Applied configuration without a reboot`

### Task 6: Validation finale

**Files:** none

- [ ] **Step 1: Cluster sans trace openebs**

Run:
```bash
kubectl get sc 2>/dev/null | grep -c openebs; kubectl get ns 2>/dev/null | grep -c openebs
kubectl get pods -A 2>/dev/null | grep -c openebs
kubectl get pv,pvc -A -o json 2>/dev/null | jq '[.items[]? | select((.spec.storageClassName // "") | contains("openebs"))] | length'
```
Expected: `0` partout

- [ ] **Step 2: Nœuds sans trace openebs**

Run: `export TALOSCONFIG=/home/nea0d/git/home-ops/talosconfig; for n in k8s-0 k8s-1 k8s-2 k8s-3; do talosctl -n $n read /proc/mounts | grep -c openebs; done`
Expected: `0` ×4

- [ ] **Step 3: Santé CNPG post-migration**

Run: `for c in litellm n8n; do kubectl cnpg status $c -n ai | grep -E "healthy|Primary"; done; kubectl cnpg status teslamate -n automation | grep healthy; kubectl cnpg status authentik -n security | grep healthy; kubectl cnpg status forgejo -n self-hosted | grep healthy; kubectl cnpg status ghostfolio -n self-hosted | grep healthy`
Expected: 6 clusters `Cluster in healthy state`, 3/3 ready

- [ ] **Step 4: Snapshots kopiur fonctionnels sur un volume migré (optionnel, démonstration CSI)**

Run: `kubectl get volumesnapshotclass 2>/dev/null | grep miroir`
Expected: classe `miroir` présente (la capacité snapshot est désormais disponible pour les volumes CNPG)

- [ ] **Step 5: Nettoyage worktree**

Run: `git worktree remove ../home-ops-openebs-miroir` (depuis le checkout principal, après merge des PRs)
Expected: worktree supprimé, branches nettoyées
