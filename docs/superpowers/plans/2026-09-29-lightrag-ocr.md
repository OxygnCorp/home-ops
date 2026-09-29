# LightRAG OCR via Docling-serve — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permettre à LightRAG d'indexer des PDF scannés en image-only en le branchant sur un service Docling-serve CPU dédié déployé sur k8s-3.

**Architecture:** Un nouveau subsystem `kubernetes/apps/ai/docling-serve/` (Flux Kustomization + OCIRepository app-template + PVC + HelmRelease) expose un Service ClusterIP `docling-serve.ai.svc.cluster.local:5001`. Le HelmRelease `lightrag` reçoit six variables d'environnement qui redirigent les PDF vers Docling (`LIGHTRAG_PARSER=pdf:docling,...`) tout en conservant intacts le chunking Tree-sitter et le fallback legacy pour les autres formats. Docling tourne en CPU-only (k8s-3 saturé en VRAM par qwen3-embed + qwen3-reranker) avec cache modèles persistant sur PVC.

**Tech Stack:** Docling-serve v1.35.0 CPU (`ghcr.io/docling-project/docling-serve-cpu`), LightRAG v1.5.7 (inchangé), bjw-s app-template 5.2.1, Flux, CloudNativePG (déjà en place, non touché).

**Spec:** `docs/superpowers/specs/2026-09-29-lightrag-ocr-design.md`

**Base:** PR #4682 mergée — la fiabilité (PG storages, rerank, role-split LLM) est préservée intacte. Ne jamais la régresse.

## Global Constraints

- **Image** : `ghcr.io/docling-project/docling-serve-cpu`, tag `v1.35.0`. Ne pas passer en image GPU (VRAM k8s-3 saturée).
- **Chart** : OCIRepository nommé `docling-serve` (un OCIRepository par app — pattern `lightrag`), `oci://ghcr.io/bjw-s-labs/helm/app-template`, tag `5.2.1`, `layerSelector.mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip`, `operation: copy`, `interval: 15m`.
- **Namespace** : `ai` — injecté par `targetNamespace` (ks.yaml) et `namespace:` (app/kustomization.yaml). **Jamais** `metadata.namespace` inline sur le HelmRelease ou la Kustomization.
- **Service** : ClusterIP, port 5001, **aucune** `route` (interne uniquement). Pas d'auth API key (D4 du spec) — isolation réseau.
- **PVC** : nom `docling-models`, 20Gi, StorageClass `openebs-hostpath`, AccessMode `ReadWriteOnce`. **Pas** de backup kopiur (D6 du spec — cache régénérable).
- **Docling env** (valeurs exactes du spec §3) : `DOCLING_SERVE_ARTIFACTS_PATH: /app/models`, `DOCLING_NUM_THREADS: "4"`, `DOCLING_SERVE_ENG_KIND: local`, `DOCLING_SERVE_ENG_LOC_NUM_WORKERS: "2"`.
- **Resources docling** : requests `cpu: 2`, `memory: 4Gi` ; limits `memory: 8Gi` (pas de limit CPU).
- **Scheduling** : nodeAffinity `preferredDuringScheduling` weight 100 sur `kubernetes.io/hostname In [k8s-3]`, toleration `workload=ai:NoSchedule`. Pas de nodeSelector dur.
- **SecurityContext pod** : `runAsNonRoot: true`, `runAsUser: 1000`, `runAsGroup: 1000`, `fsGroup: 1000`, `fsGroupChangePolicy: OnRootMismatch`.
- **SecurityContext container** : `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`.
- **Strategy** : `Recreate` (singleton, pas de rolling update).
- **LightRAG env ajouté** (valeurs exactes du spec §2) : `LIGHTRAG_PARSER: "pdf:docling,*:native-teP,*:legacy-R"`, `DOCLING_ENDPOINT: "http://docling-serve.ai.svc.cluster.local:5001"`, `DOCLING_DO_OCR: "true"`, `DOCLING_FORCE_OCR: "false"`, `MAX_PARALLEL_PARSE_DOCLING: "2"`, `DOCLING_TIMEOUT: "300"`.
- **`LIGHTRAG_PARSER` remplace** la valeur existante `"*:native-teP,*:legacy-R"` — c'est une modification, pas un ajout.
- **Fichiers YAML** : commencer par `---`, suivre les conventions du repo (commentaires `# yaml-language-server: $schema=...`, clés en camelCase pour les CRD Flux, en snake_case pour les clés d'env LightRAG).
- **TDD** : non applicable (repo config-only GitOps, aucune logique exécutable). Le gate de vérification est `flate` (§ Validate locally dans AGENTS.md) + konflate + vérification cluster post-merge. Ce ruling est déjà porté par le ledger de la PR #4682.
- **Stage uniquement tes propres fichiers** — jamais `git add -A` ni `git add .` (règle globale AGENTS.md).

## Review Focus

Cinq classes d'échecs que le spec implique mais qu'aucune tâche ne teste par construction — de la plus probable à la moins probable :

1. **Cold cache → crash loop au premier déploiement.** Le premier démarrage télécharge ~4 GB de modèles. Le startup probe doit absorber ce pic, sinon le pod est tué en boucle et le déploiement n'atteint jamais Ready. → Le startup probe doit tolérer 5 min (`failureThreshold: 30` × `periodSeconds: 10`).
2. **PDF mixte sur-OCRisé.** `DOCLING_FORCE_OCR=true` ferait passer les pages déjà textuelles dans l'OCR inutilement (×3 temps de traitement sur un corpus de contrats). Le spec tranche à `false` (D7) — c'est le comportement par défaut qu'une personne qui upload un PDF textuel attend.
3. **OOM sur PDF de 200+ pages.** Un document technique long sans limite mémoire fait kill -9 le pod en plein traitement ; la tâche async est perdue sans trace exploitable. La limite mémoire doit exister et être dimensionnée pour le pic (8Gi).
4. **Doublon d'OCIRepository.** Le chart est partagé mais chaque app a son propre OCIRepository (pattern `lightrag`, pas `app-template`). Un OCIRepository nommé `app-template` dupliquerait/conflicterait avec celui de `lightrag`.
5. **Version skew LightRAG ↔ Docling.** LightRAG épingle v1.5.7 et parle une API HTTP figée à une version donnée de Docling. Un bump de l'un sans l'autre casse silencieusement l'extraction. Les deux versions doivent être pinnées et le couplage documenté en commentaire.

---

## File Structure

| Fichier | Responsabilité |
|---|---|
| `kubernetes/apps/ai/docling-serve/ks.yaml` | Flux Kustomization : path, targetNamespace `ai`, prune, commonMetadata label `app.kubernetes.io/name: docling-serve` |
| `kubernetes/apps/ai/docling-serve/app/ocirepository.yaml` | OCIRepository `docling-serve` → app-template 5.2.1 |
| `kubernetes/apps/ai/docling-serve/app/pvc.yaml` | PVC `docling-models` 20Gi `openebs-hostpath` RWO |
| `kubernetes/apps/ai/docling-serve/app/helmrelease.yaml` | Deployment + Service ClusterIP 5001 + env + probes + resources + scheduling + persistence |
| `kubernetes/apps/ai/docling-serve/app/kustomization.yaml` | Kustomize : namespace `ai`, liste des 4 ressources |
| `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` | **Modifier** : remplacer `LIGHTRAG_PARSER`, ajouter 5 vars Docling |
| `docs/superpowers/plans/2026-09-29-lightrag-ocr.md` | Ce plan |

---

### Task 1: Déployer docling-serve

**Files:**
- Create: `kubernetes/apps/ai/docling-serve/ks.yaml`
- Create: `kubernetes/apps/ai/docling-serve/app/ocirepository.yaml`
- Create: `kubernetes/apps/ai/docling-serve/app/pvc.yaml`
- Create: `kubernetes/apps/ai/docling-serve/app/helmrelease.yaml`
- Create: `kubernetes/apps/ai/docling-serve/app/kustomization.yaml`

**Interfaces:**
- Consumes: rien (première tâche). Le namespace `ai` existe déjà (créé par `lightrag` et autres apps du même namespace).
- Produces: Service `docling-serve` dans le namespace `ai` sur le port 5001, joignable à `http://docling-serve.ai.svc.cluster.local:5001`. C'est cette URL exacte que la Task 2 consigne dans `DOCLING_ENDPOINT`.

- [ ] **Step 1: Créer l'OCIRepository**

Créer `kubernetes/apps/ai/docling-serve/app/ocirepository.yaml`. Copier la structure de `kubernetes/apps/ai/lightrag/app/ocirepository.yaml` exactement, en changeant **uniquement** `metadata.name: lightrag` → `metadata.name: docling-serve`. L'URL du chart, le `ref.tag: 5.2.1`, le `layerSelector` et l'`interval: 15m` sont identiques — même chart, un OCIRepository par app (cf. Review Focus #4).

- [ ] **Step 2: Créer le PVC du cache modèles**

Créer `kubernetes/apps/ai/docling-serve/app/pvc.yaml` :

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/v1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: docling-models
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 20Gi
  # Local, non répliqué : le cache modèles est régénérable
  # (re-téléchargement ~4 GB, cf. spec §5). Pas de backup kopiur
  # pour 5 GB de cache dérivable.
  storageClassName: openebs-hostpath
```

- [ ] **Step 3: Créer le HelmRelease docling-serve**

Créer `kubernetes/apps/ai/docling-serve/app/helmrelease.yaml`. Structure et conventions copiées de `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` :

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: docling-serve
spec:
  chartRef:
    kind: OCIRepository
    name: docling-serve
  interval: 1h
  values:
    controllers:
      docling-serve:
        annotations:
          reloader.stakater.com/auto: "true"
        strategy: Recreate
        containers:
          app:
            image:
              repository: ghcr.io/docling-project/docling-serve-cpu
              # Pinned: LightRAG v1.5.7 parle une API HTTP figée à
              # cette version de Docling. Bump conjoint requis (cf. spec §5).
              tag: v1.35.0
            env:
              # Cache modèles persistant sur le PVC (~4 GB au 1er boot).
              DOCLING_SERVE_ARTIFACTS_PATH: /app/models
              # k8s-3 expose 4 cores aux pods (default upstream = 4).
              DOCLING_NUM_THREADS: "4"
              DOCLING_SERVE_ENG_KIND: local
              DOCLING_SERVE_ENG_LOC_NUM_WORKERS: "2"
            probes:
              # TCP : Docling n'expose pas de /livez dédié.
              liveness:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: 5001
                  initialDelaySeconds: 30
                  periodSeconds: 30
                  timeoutSeconds: 5
                  failureThreshold: 5
              # /health vérifie que les modèles sont chargés, pas juste que
              # le process répond.
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: 5001
                  initialDelaySeconds: 15
                  periodSeconds: 15
                  timeoutSeconds: 5
                  failureThreshold: 3
              # 30 x 10s = 5 min de tolérance pour le téléchargement
              # initial des 4 GB de modèles (cf. Review Focus #1).
              startup:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /health
                    port: 5001
                  periodSeconds: 10
                  failureThreshold: 30
            resources:
              requests:
                cpu: 2
                memory: 4Gi
              limits:
                # Pas de limit CPU : on veut qu'il prenne ce qu'il peut
                # sur le bare metal k8s-3. Mémoire bornée pour éviter
                # un kill -9 silencieux sur PDF de 200+ pages (spec §5).
                memory: 8Gi
            securityContext:
              allowPrivilegeEscalation: false
              capabilities:
                drop:
                  - ALL
              seccompProfile:
                type: RuntimeDefault
    defaultPodOptions:
      # Même scheduling que lightrag : préférence k8s-3 (bare metal,
      # CPU/RAM récents) mais schedulable ailleurs si saturé.
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              preference:
                matchExpressions:
                  - key: kubernetes.io/hostname
                    operator: In
                    values: [k8s-3]
      tolerations:
        - key: workload
          operator: Equal
          value: ai
          effect: NoSchedule
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
    persistence:
      data:
        existingClaim: docling-models
        globalMounts:
          - path: /app/models
    service:
      app:
        # ClusterIP interne seulement — aucune route. LightRAG est le seul
        # client (cf. spec D4 : pas d'auth, isolation réseau).
        type: ClusterIP
        ports:
          http:
            port: 5001
```

Noter l'absence de `route:` (contrairement à lightrag) et l'absence de `upgrade.force` (non requis — le chart est immutable, le tag est pinné).

- [ ] **Step 4: Créer le kustomization.yaml de l'app**

Créer `kubernetes/apps/ai/docling-serve/app/kustomization.yaml` :

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ai
resources:
  - ./ocirepository.yaml
  - ./pvc.yaml
  - ./helmrelease.yaml
```

- [ ] **Step 5: Créer la Flux Kustomization**

Créer `kubernetes/apps/ai/docling-serve/ks.yaml` :

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: docling-serve
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: docling-serve
  interval: 1h
  path: ./kubernetes/apps/ai/docling-serve/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: ai
  timeout: 5m
  wait: false
```

Pas de `components:` (ni postgres ni kopiur — le PVC est volontairement sans backup) et pas de `dependsOn:` (docling-serve ne dépend d'aucun autre subsystem ; litellm n'est nécessaire qu'à lightrag, pas à docling).

- [ ] **Step 6: Valider le rendu avec flate**

Run:
```bash
mise exec -- flate test ks --path ./kubernetes/apps
mise exec -- flate test hr --path ./kubernetes/apps
```
Expected: les deux commandes passent sans erreur, et le compte de Kustomizations passe de 115 à 116 (le nouveau `docling-serve` apparaît). Si flate signale une erreur de schéma sur les nouveaux fichiers, la corriger avant de continuer.

- [ ] **Step 7: Committer**

```bash
git add kubernetes/apps/ai/docling-serve/
git commit -m "feat(ai): deploy docling-serve for scanned PDF OCR

CPU-only docling-serve v1.35.0 (bjw-s app-template) on k8s-3, ClusterIP
port 5001, model cache on a 20Gi openebs-hostpath PVC. Backs the Docling
parser rule added to lightrag in the next commit."
```

---

### Task 2: Brancher LightRAG sur Docling

**Files:**
- Modify: `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` (bloc `env` sous `controllers.lightrag.containers.app`, section "Chunking / parsing")

**Interfaces:**
- Consumes: le Service `docling-serve.ai.svc.cluster.local:5001` produit par la Task 1.
- Produces: un LightRAG qui route les PDF vers `pdf:docling` et conserve `*:native-teP,*:legacy-R` pour les autres formats.

- [ ] **Step 1: Remplacer LIGHTRAG_PARSER et ajouter les variables Docling**

Dans `kubernetes/apps/ai/lightrag/app/helmrelease.yaml`, localiser le groupe de commentaires `# Chunking / parsing` et le bloc `env` correspondant. Remplacer :

```yaml
              # Chunking / parsing
              CHUNK_SIZE: "1000"
              CHUNK_OVERLAP_SIZE: "100"
              LIGHTRAG_PARSER: "*:native-teP,*:legacy-R"
```

par :

```yaml
              # Chunking / parsing
              CHUNK_SIZE: "1000"
              CHUNK_OVERLAP_SIZE: "100"
              # pdf:docling route les PDF (y compris scannés image-only) vers
              # docling-serve pour OCR + extraction de structure. Les autres
              # formats gardent le chunking Tree-sitter (native-teP) et le
              # fallback legacy-R. L'ordre des règles est significatif :
              # la première règle matchant gagne.
              LIGHTRAG_PARSER: "pdf:docling,*:native-teP,*:legacy-R"
              # Service interne (ClusterIP, aucune route) — cf. spec D4 :
              # pas d'auth API key, isolation réseau uniquement.
              DOCLING_ENDPOINT: "http://docling-serve.ai.svc.cluster.local:5001"
              # OCR activé pour les pages image-only.
              DOCLING_DO_OCR: "true"
              # false = n'OCR que les pages sans couche texte. Évite le ×3 de
              # temps de traitement sur un PDF mixte (contrats avec pages
              # scannées ET pages textuelles) — cf. spec D7.
              DOCLING_FORCE_OCR: "false"
              # 2 conversions PDF en parallèle (default upstream = 1) pour
              # réduire le temps total d'indexation d'un lot — cf. spec D8.
              MAX_PARALLEL_PARSE_DOCLING: "2"
              # 5 min : generous pour un PDF technique avec tableaux complexes
              # au premier passage (warmup modèles).
              DOCLING_TIMEOUT: "300"
```

**Ne pas toucher** au reste du fichier : `strategy`, `image`, les blocs `envFrom`, les `probes`, `resources`, `securityContext`, `defaultPodOptions`, `persistence`, `service`, `route`, ni aucune variable PG / embedding / rerank / LLM. La fiabilité de la PR #4682 est intouchable.

- [ ] **Step 2: Vérifier que l'URL du Step 1 correspond au Service de la Task 1**

Run:
```bash
grep -n "port: 5001" kubernetes/apps/ai/docling-serve/app/helmrelease.yaml
grep -n "DOCLING_ENDPOINT" kubernetes/apps/ai/lightrag/app/helmrelease.yaml
```
Expected: `port: 5001` dans le Service docling-serve, et l'URL `http://docling-serve.ai.svc.cluster.local:5001` dans le HelmRelease lightrag. Les deux doivent correspondre exactement — un port ou un nom de Service divergent produit un 404 silencieux au runtime.

- [ ] **Step 3: Valider le rendu avec flate**

Run:
```bash
mise exec -- flate test hr --path ./kubernetes/apps
```
Expected: passe sans erreur, compte de HelmReleases inchangé (84 → 85, le nouveau `docling-serve` de la Task 1 compte déjà).

- [ ] **Step 4: Committer**

```bash
git add kubernetes/apps/ai/lightrag/app/helmrelease.yaml
git commit -m "feat(ai): route lightrag PDFs through docling for OCR

LIGHTRAG_PARSER gains a leading pdf:docling rule; the native-teP and
legacy-R wildcard rules stay as fallbacks for non-PDF formats. Sets
DOCLING_DO_OCR with DOCLING_FORCE_OCR=false so mixed PDFs only OCR their
image-only pages. POSTGRES_*, EMBEDDING_*, RERANK_* and the role-split
LLM config from #4682 are untouched."
```

---

### Task 3: Diff vs main et ouverture de PR

**Files:**
- None (vérification + intégration)

**Interfaces:**
- Consumes: les commits des Tasks 1 et 2 sur `feat/lightrag-ocr`.
- Produces: une PR mergée dans `main`, donc le cluster qui réconcilie docling-serve + lightrag via Flux.

- [ ] **Step 1: Diff flate contre origin/main**

```bash
git fetch origin
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```
Expected: le diff KS montre exactement un ajout (la Kustomization `docling-serve` + ses composants), le diff HR montre exactement le nouveau HelmRelease `docling-serve` et la modification de `lightrag`. **Rien d'autre** — si un autre fichier apparaît dans le diff, c'est un bug : ne pas merger avant d'avoir identifié pourquoi.

- [ ] **Step 2: Pousser la branche et ouvrir la PR**

```bash
git push -u origin feat/lightrag-ocr
gh pr create --base main --head feat/lightrag-ocr \
  --title "feat(ai): index scanned PDFs in lightrag via docling-serve" \
  --body "$(cat <<'EOF'
## Contexte

LightRAG ne peut pas indexer de PDF scannés image-only : son parser natif
n'extrait que la couche texte. Upstream documente Docling (ou MinerU) comme
parseur externe pour ce cas.

Suite de #4682 (fiabilité), qui a posé le stockage PostgreSQL/pgvector.
Cette PR ajoute OCR **sans régresser** la config acquise.

## Contenu

- Nouveau subsystem `ai/docling-serve` : docling-serve v1.35.0 CPU-only
  (bj-s app-template), ClusterIP port 5001, schedulé préférentiellement sur
  k8s-3, cache modèles sur PVC 20Gi `openebs-hostpath` (non sauvegardé :
  cache régénérable).
- `lightrag` : `LIGHTRAG_PARSER` gagne une règle `pdf:docling` en tête de
  chaîne, `DOCLING_DO_OCR=true` avec `DOCLING_FORCE_OCR=false` (un PDF
  mixte n'OCR que ses pages image-only).

## Décisions

- **Docling plutôt que MinerU** (recommandé par upstream) : CPU-only
  out-of-the-box, sans GPU disponible sur ce cluster (la VRAM de
  k8s-3 est déjà prise par qwen3-embedding + qwen3-reranker), formats
  additionnels (md/html/xhtml/tiff), sortie LaTeX pour les équations.
- **Pas de GPU** : la VRAM de k8s-3 est déjà prise par qwen3-embedding +
  qwen3-reranker (llama.cpp) qui servent lightrag et memini. Docling CPU
  tient le volume (50-500 docs).
- **Pas d'auth API key** sur docling-serve : Service ClusterIP sans route,
  seul LightRAG est client. Une exposition publique imposerait un reverse
  proxy.
- **Pas de backup kopiur** sur le cache modèles : ~4-5 GB de données
  entièrement dérivées par re-téléchargement, pas de valeur de
  restauration.

## Inchangé (volontairement)

`POSTGRES_*`, `EMBEDDING_*`, `RERANK_*`, le role-split LLM
(`dsv41f-nothink` / `MiniMax-M3`), les resources, probes et scheduling de
lightrag : la config de #4682 est intacte. Seul le bloc `env` de parsing
est étendu.

## Vérification

- [ ] `flate test ks` / `flate test hr` verts (compte KS 115 → 116)
- [ ] konflate : diff rendu conforme
- [ ] post-merge : docling-serve Ready, `/health` 200, upload d'un PDF
      scanné de test indexé sans erreur
EOF
)"
```
Expected: l'URL de la PR est renvoyée. Noter le numéro.

- [ ] **Step 3: Attendre les checks CI**

```bash
gh pr checks <N> --watch
```
Expected: `flate` (ou le check de validation du repo) et `konflate` au vert. Si konflate signale un écart de rendu non intentionnel, ne pas merger : investiguer d'abord.

- [ ] **Step 4: Merger**

```bash
gh pr merge <N> --squash --delete-branch
```
Expected: PR mergée dans `main`. La branche distante est supprimée par GitHub ; la branche locale reste jusqu'au nettoyage du worktree en fin de run (le commit est un ancêtre de `origin/main` après le squash, donc le worktree est supprimable — vérifier avec `wt-prune.sh` en dry-run avant `--apply`).

---

### Task 4: Vérification post-merge sur le cluster

**Files:**
- None (inspection seule)

**Interfaces:**
- Consumes: la PR mergée de la Task 3, réconciliée par Flux.
- Produces: la preuve que le subsystem fonctionne — c'est cette preuve qui clôt le plan.

- [ ] **Step 1: Vérifier la réconciliation Flux**

```bash
flux get ks -n ai docling-serve
flux get hr -n ai docling-serve
```
Expected: Kustomization `Ready=True` avec le message `Applied revision` ; HelmRelease `Ready=True`. Si la KS est `blocked`, regarder `dependsOn` — docling-serve n'en a aucun, donc un blocageviendrait d'une référence cassée (OCIRepository absent ou mauvais path).

- [ ] **Step 2: Vérifier le pod et le health endpoint**

```bash
kubectl get pods -n ai -l app.kubernetes.io/name=docling-serve
kubectl exec -n ai deploy/docling-serve -- curl -sf http://localhost:5001/health
```
Expected: pod `1/1 Running` ; `/health` retourne un JSON de succès (code 0). **Le premier boot télécharge ~4 GB** : laisser jusqu'à 15 min avant de conclure à un échec. Si le pod est en `CrashLoopBackOff`, lire les logs — c'est le scénario Review Focus #1 (startup probe trop court, ou échec réseau de téléchargement des modèles).

- [ ] **Step 3: Vérifier le cache modèles persisté**

```bash
kubectl exec -n ai deploy/docling-serve -- ls -la /app/models | head -20
kubectl exec -n ai deploy/docling-serve -- du -sh /app/models
```
Expected: plusieurs fichiers de modèle présents, total de l'ordre de 2 à 5 Go. Un répertoire vide signifie que `DOCLING_SERVE_ARTIFACTS_PATH` ne pointe pas sur le volume monté — vérifier que `persistence.data.existingClaim: docling-models` résout bien.

- [ ] **Step 4: Vérifier la config LightRAG côté cluster**

```bash
kubectl logs -n ai deploy/lightrag --tail=200 | grep -iE "docling|parser"
```
Expected: une ligne indiquant le parser configuré et l'endpoint Docling. Si LightRAG refuse de démarrer avec une erreur du type « rule requires DOCLING_ENDPOINT », c'est que la variable n'a pas été rendue — vérifier le HelmRelease effectivement appliqué (`flux get hr lightrag -n ai -o yaml`) et non le fichier Git.

- [ ] **Step 5: Confirmer l'absence de régression PR #4682**

```bash
kubectl logs -n ai deploy/lightrag --tail=500 | grep -iE "Reranking is enabled|Role LLM|PGVectorStorage|PGTableGraphStorage|query_prefix"
kubectl logs -n ai deploy/lightrag --tail=500 | grep -icE "NanoVectorDB|flush failed|Traceback"
```
Expected :
- `Reranking is enabled: qwen3-reranker-0.6b` — rerank intact.
- Les 4 role-LLM (`extract`, `keyword`, `query`) — config de rôle intacte.
- `PGVectorStorage` / `PGTableGraphStorage` / `PGKVStorage` / `PGDocStatusStorage` — stockage PG intact.
- Le second compte = **0** — pas de régression.

- [ ] **Step 6: Tester l'indexation d'un PDF scanné**

L'utilisateur upload via l'UI (`https://lightrag.oxygn.dev`) ou l'API un PDF scanné de test. Ensuite :

```bash
kubectl logs -n ai deploy/lightrag --since=10m | grep -iE "docling|processed|failed" | tail -20
kubectl exec -n ai lightrag-1 -c postgres -- psql -U postgres -d lightrag -tA -c "select count(*) from lightrag_doc_status where status = 'processed'"
```
Expected : le log montre le document `processed` (pas `failed`) ; le compte `processed` est supérieur à zéro. Un `failed` ici avec un message Docling dans les logs docling-serve indique soit un timeout (monter `DOCLING_TIMEOUT`), soit un OOM (cf. Review Focus #3 — le log docling-serve nomme la page fautive).

- [ ] **Step 7: Vérifier les ressources sous charge**

```bash
kubectl top pod -n ai -l app.kubernetes.io/name=docling-serve
```
Expected : CPU < 4 cores, mémoire < 8Gi. Si la mémoire colle à 8Gi en régime permanent, les 4Gi de requests sont sous-dimensionnés pour le volume réel — ouvrir une PR de tuning plutôt que d'ignorer.

- [ ] **Step 8: Nettoyer le worktree**

Après vérification verte :
```bash
cd /home/nea0d/git/home-ops
~/.config/opencode/bin/wt-prune.sh --only feat/lightrag-ocr
```
Expected: rapport `branche ancêtre de origin/main`. Relancer avec `--apply` pour supprimer le worktree et la branche. Jamais `--force`.

Si la vérification échoue à une étape, **ne pas** nettoyer : garder le worktree pour itérer, et rapporter l'étape exacte qui a échoué avec la sortie de la commande.
