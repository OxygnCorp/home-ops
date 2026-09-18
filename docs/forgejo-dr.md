# Forgejo DR — source de vérité git (mirror passif)

Forgejo (`git.oxygn.dev`, namespace `self-hosted`) est un **pull-mirror passif** de
`github.com/OxygnCorp` : il sert uniquement de copie locale au cas où GitHub ou le serveur
Proxmox deviennent inaccessibles. Rien d'autre dans le cluster n'en dépends.

## Chaîne de survie

```
GitHub (source de vérité)
  ↳ pull-mirror 15min (Forgejo UI, état applicatif)
Forgejo PVC (miroir-slow)
  ↳ kopiur horaire (Kopia)
NFS (funkstation)
  ↳ réplication NAS → bucket R2 Cloudflare
```

Le clone peut être récupéré depuis **trois** endroits : GitHub (SaaS), `git.oxygn.dev` (LAN),
ou le restore kopiur (NFS/R2).

## 1. Incident : perte de GitHub uniquement (cluster OK)

Forgejo continue de servir la dernière sync (lag max 15 min).

```bash
git clone https://git.oxygn.dev/OxygnCorp/home-ops.git ~/git/home-ops-dr
# push vers un nouveau remote (GitHub import, ou un repo forgejo-writable temporaire)
```

Traiter les PRs ouvertes sur GitHub : orphelines pendant l'incident, à re-soumettre après.
Recovery pipeline: nothing to do; Forgejo rebuild itself from latest snapshot once available.

## 2. Incident : perte GitHub + serveur Proxmox (cluster down)

La source de vérité reste disponible si le mirror a déjà atterri sur NFS/R2:

### Depuis le poste local

Le plus court chemin : re-cloner depuis GitHub dès que celui-ci redevient joignable, ou
depuis le bucket R2 (item Kopia restauré) —

```bash
# Restore du PVC forgejo via kopiur depuis le NAS (après avoir remonté un cluster minimal)
# puis clone LAN:
git clone https://git.oxygn.dev/OxygnCorp/home-ops.git
```

Les items secrets 1Password ((`forgejo`, les ExternalSecrets) et le binaire `op` restent
sur la machine cliente — ils sont indépendants du cluster.

## 3. Incident : perte totale (serveur + cluster)

Remonter la stack dans cet ordre :

1. Remonter l'hyperviseur Proxmox (machine indépendante)
2. Talon : `just talos apply-node` pour chaque nœud, puis bootstrap (Talos → k8s)
3. **Bootstrap depuis le mirror local** :

   ```
   git clone https://git.oxygn.dev/OxygnCorp/home-ops.git
   cd home-ops && just bootstrap cluster
   ```

   Le `GitRepository flux-system` créé par flux-instance pointe vers GitHub ; si celui-ci
   reste injoignable, répointer temporairement vers la forge locale en éditant
   `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` (`.values.instance.sync.url`)
   avant le bootstrap, puis revert quand GitHub revient.

4. Si la forge ne redémarre pas — restore du PVC :

   ```bash
   # PVC Destroy (optionnel) → Flux = clôture du PVC
   kubectl -n self-hosted delete pv forgejo --ignore-not-found
   kubectl -n self-hosted annotate kustomization forgejo force-sync=true --overwrite
   # flux réconcilie et re-srût le PVC via le Restore populator kopiur
   ```

## 4. Forcer la re-sync du mirror

```bash
just kube mirror-sync OxygnCorp
```

Création/mise à jour des mirrors : `just kube mirror-all OxygnCorp`.

## 5. Checklist mensuelle (drill léger)

- `just kube sync` OK
- `git ls-remote https://git.oxygn.dev/OxygnCorp/home-ops` retourne bien les refs
- `kubectl get snapshotschedule forgejo -n self-hosted` — dernière backup < 2h
- Item 1Password `forgejo` : GITHUB_TOKEN non-expiré (PAT fine-grained org, Contents+Metadata read-only)
