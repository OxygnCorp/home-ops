# LightRAG OCR — Design Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:brainstorming → superpowers:writing-plans to transform this spec into an implementation plan.

**Goal:** Permettre à LightRAG d'indexer des PDF scannés (image-only) en branchant un service Docling dédié pour l'OCR et l'extraction de structure, tout en préservant la fiabilité acquise (Postgres/pgvector, rerank, role-split LLM, CNPG cluster) issue de PR #4682.

**Architecture:** LightRAG appelle Docling-serve via HTTP asynchrone (`POST /v1/convert/file/async` → poll status → GET result), le markdown retourné suit le pipeline d'extraction/chunking/embedding existant. Docling-serve tourne dans son propre Deployment (HelmRelease + bjw-s app-template) sur k8s-3 (CPU, hors GPU saturé), avec cache modèles persistant sur PVC `openebs-hostpath`.

**Tech Stack:**
- Docling-serve v1.35.0 (`ghcr.io/docling-project/docling-serve-cpu`), CPU-only.
- LightRAG v1.5.7 (déjà déployé, upgrade non requis).
- bjw-s app-template chart 5.2.1 (même pattern que `lightrag`).
- StorageClass `openebs-hostpath` pour le cache modèles (local, pas critique).

**Spec refonte antérieure:** `docs/superpowers/specs/2026-09-28-lightrag-reliability-design.md` (PR #4682 mergée). Ce spec étend la base fiable acquise ; ne la régresse pas.

---

## 1. Architecture

### Flow d'indexation (post-PR #4682 + OCR)

```
[UI/MCP/API upload]
        ↓
[LightRAG v1.5.7 — port 9621]
   - content type détecté → rule parser
   - PDF → rule `pdf:docling`
        ↓ POST /v1/convert/file/async (multipart)
[Docling-serve v1.35.0 — port 5001, k8s-3]
   - layout analysis (RT-DETR, TableFormer)
   - OCR si nécessaire (EasyOCR/Tesseract backend CPU)
   - export markdown + JSON
        ↓ poll /v1/status/poll/{task_id}?wait=5
        ↓ GET /v1/result/{task_id} (zip)
[LightRAG — pipeline post-OCR]
   - text chunks (markdown) → embedder (qwen3-embedding-0.6b, GPU)
   - chunks → extract/keyword LLM (dsv41f-nothink via litellm)
   - entities + relations → PGTableGraph
   - vectors → PGVector (HNSW)
   - doc_status → PGDocStatus
```

### Composants Kubernetes (nouveaux)

```
kubernetes/apps/ai/docling-serve/
├── ks.yaml                           # Flux Kustomization
└── app/
    ├── ocirepository.yaml            # app-template chart
    ├── pvc.yaml                      # PVC docling-models (20Gi, openebs-hostpath)
    ├── helmrelease.yaml              # Deployment + Service + values app-template
    └── kustomization.yaml            # namespace: ai, resources
```

### Composants modifiés

- `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` : ajout env vars OCR (parser, endpoint, parallelism). Aucun changement au Deployment (image, storage, Reranker, LLM restent identiques).

---

## 2. LightRAG — Configuration OCR

Variables d'environnement ajoutées au HelmRelease `lightrag` (les valeurs PG/Reranker/LLM/Embedding de PR #4682 restent intactes) :

| Variable | Valeur | Raison |
|---|---|---|
| `LIGHTRAG_PARSER` | `pdf:docling,*:native-teP,*:legacy-R` | Redirige les PDF vers Docling, conserve le chunking Tree-sitter + fallback pour les autres types. |
| `DOCLING_ENDPOINT` | `http://docling-serve.ai.svc.cluster.local:5001` | URL interne (Service ClusterIP, pas de route publique). |
| `DOCLING_DO_OCR` | `true` | Active l'OCR pour les pages image-only. |
| `DOCLING_FORCE_OCR` | `false` | Pour PDF mixtes : utilise le texte natif s'il existe, OCR seulement si nécessaire. Évite l'OCR inutile sur PDF déjà textuels (gain perf ×3 sur contrats). |
| `MAX_PARALLEL_PARSE_DOCLING` | `2` | Upstream default=1 ; on monte à 2 pour paralléliser l'upload de plusieurs docs simultanés (volume 50–500 docs, on accepte une charge concurrente modérée). |
| `DOCLING_TIMEOUT` | `300` | 5 min — generous, documents techniques avec tableaux complexes peuvent être lents au premier passage (warmup modèles). |

**Pas de clé API Docling côté LightRAG** : l'API Docling-serve est interne (Service ClusterIP sans route). LightRAG upstream n'envoie pas de header `X-Api-Key` même s'il était configuré ; on s'appuie sur l'isolation réseau (pas d'Ingress, pas de route HTTP) et le NetworkPolicy cluster par défaut.

### Validation au démarrage

LightRAG valide au startup que `pdf:docling` exige `DOCLING_ENDPOINT` non vide → erreur claire si manquant. Côté Docling-serve, `/health` doit répondre 200 avant que la readiness de LightRAG passe (mais les deux démarrent en parallèle ; LightRAG fallback gracieux : si Docling indisponible, message d'erreur sur le PDF mais pas de crash global).

---

## 3. Docling-serve — Déploiement

### Image et ressources

- **Image** : `ghcr.io/docling-project/docling-serve-cpu:v1.35.0` (released 2026-09-23).
- **Replicas** : 1 (suffisant pour 50–500 docs ; scale up seulement si on observe une saturation CPU).
- **Ressources** :
  - requests : cpu `2`, memory `4Gi`
  - limits : memory `8Gi` (pas de limit CPU — on veut qu'il prenne ce qu'il peut sur k8s-3 bare-metal).
- **Sécurité** : `runAsNonRoot`, `runAsUser: 1000`, `drop ALL`, `seccompProfile: RuntimeDefault`, `allowPrivilegeEscalation: false`. Identique au pod LightRAG.

### Variables d'environnement

| Variable | Valeur | Raison |
|---|---|---|
| `DOCLING_SERVE_ARTIFACTS_PATH` | `/app/models` | Cache modèles persistant sur PVC. Téléchargement initial ~4 GB. |
| `DOCLING_NUM_THREADS` | `4` | k8s-3 a 4 cores visibles aux pods ; default upstream=4 coïncide. |
| `DOCLING_SERVE_ENG_KIND` | `local` | Compute engine in-process ; pas besoin de broker externe. |
| `DOCLING_SERVE_ENG_LOC_NUM_WORKERS` | `2` | 2 workers en parallèle pour les tâches async ; reste 2 threads pour I/O. |

**Pas de `DOCLING_SERVE_API_KEY`** : on désactive l'auth pour simplifier. Service interne, isolation réseau uniquement. (Si exposition publique un jour → reverse proxy + clé ; pas le cas ici.)

### Probes

- **Liveness** : TCP socket port 5001 (Docling n'a pas de `/livez`, le port ouvert suffit pour le cas "process vivant").
- **Readiness** : HTTP `GET /health` (existe nativement côté Docling-serve, vérifie modèles chargés).
- **Startup** : HTTP `GET /health` avec `failureThreshold: 30`, `periodSeconds: 10` → tolérance 5 min pour le chargement initial des modèles (téléchargement + warmup depuis le cache PVC).

### Stockage

- **PVC `docling-models`** : 20Gi, StorageClass `openebs-hostpath`, AccessMode `ReadWriteOnce`.
- Pas de kopiur backup (cache modèles régénérable ; re-téléchargement 4GB acceptable en cas de perte — événement rare, downtime ~5 min).
- VolumeBindingMode : `WaitForFirstConsumer` (default `openebs-hostpath`) — la PVC se bind au node où le pod schedule.

### Scheduling

- **nodeAffinity preferred** : `kubernetes.io/hostname=k8s-3` weight 100 (bare metal, RAM et CPU récents).
- **Toleration** : `workload=ai:NoSchedule` (pour rester sur le pool AI workloads, identique à LightRAG).
- **Pas de fallback dur** : si k8s-3 saturé (peu probable avec 1 replica), le pod ira sur k8s-0/1/2. Docling-serve tourne sans GPU.

### Service

- Type `ClusterIP`, port 5001, targetPort 5001. Pas de route HTTP (interne uniquement).

### Stratégie de mise à jour

- `strategy.type: Recreate` (singleton) — un seul replica, pas de rolling update, on coupe et on recrée.
- Pas de PDB nécessaire (singleton non critique ; downtime toléré).

---

## 4. Considérations opérationnelles

### Warmup au premier démarrage

Le **premier** démarrage de Docling-serve télécharge ~4 GB de modèles (layout, table, OCR backends) dans `/app/models`. Temps estimé : 5–15 min selon bande passante réseau. Le startup probe tolère jusqu'à 5 min — au-delà, le pod sera marqué Failed et Flux retentera.

Une fois les modèles en cache (survit aux restarts), les démarrages suivants sont < 30 s.

### Coût CPU attendu

Sur k8s-3 (bare metal, 4 cores visibles) :
- Docling-serve : 2 workers × 4 threads = 8 threads logiques (oversubscription OK sur CPU bare metal).
- Traitement d'un PDF scanné de 20 pages : ~30 s en moyenne (layout + OCR + table extraction).
- 50 docs × 30 s ÷ 2 workers = ~12 min total en séquentiel, parallélisable à ~6 min si les uploads arrivent en batch.

### Backpressure vers LightRAG

LightRAG upstream poll toutes les 5 s. Si Docling est saturé (queue pleine côté `local` engine), le poll continue — Docling bufferise en interne. Pas de risque de timeout côté LightRAG tant que `DOCLING_TIMEOUT=300` (5 min par tâche).

### Mise à l'échelle future

Si le volume passe à >1000 docs/scannering/semaine :
1. Augmenter replicas à 2 (load balancing naïf via Service DNS round-robin — Docling-serve supporte les requêtes concurrentes).
2. Ou passer à `DOCLING_SERVE_ENG_KIND=broker` (Kafka/RabbitMQ) pour découpler ingestion/traitement — non requis à ce stade.

### Monitoring (différé)

Pas de PrometheusRule ou GrafanaDashboard dans cette PR. Les métriques Docling-serve exposées au format Prometheus sur `/metrics` ne sont pas scrapées pour l'instant. Si la saturation devient un problème, ajouter un ServiceMonitor + PodMonitor dans une PR ultérieure.

---

## 5. Risques et mitigations

| Risque | Impact | Mitigation |
|---|---|---|
| Docling-serve OOM sur PDF de 200+ pages | Pod restart, perte tâche en cours | Limit memory 8Gi, restart strategy Recreate. Docling-serve log explicitement la page fautive ; on peut alors découper le PDF avant ré-upload. |
| Modèles pas encore cachés au premier déploiement | Démarrage lent 10-15 min | Startup probe tolère 5 min × 30 essais. Au-delà, échec clair côté Flux. Acceptable pour un déploiement initial. |
| k8s-3 saturé CPU | Docling-serve + LightRAG + qwen3-embed + qwen3-reranker en concurrence | LightRAG et embed/rerank sont déjà sur k8s-3 ; Docling vient s'ajouter. Bare metal 4 cores = load moyen attendu ~70%. Si saturation : scinder vers k8s-0/1/2 (déjà autorisé via nodeAffinity preferred, pas de taint dur). |
| Conflit de version LightRAG ↔ Docling API | Rupture si LightRAG change l'API HTTP attendue | LightRAG s'auto-valide au startup (erreur claire). On pin Docling v1.35.0 ; bump conjoint LightRAG + Docling nécessaire si rupture API. |
| Cache modèles corrompu (extinction brutale k8s-3) | Docling-serve KO au prochain démarrage | Pas de backup (décision consciente). Re-téléchargement 4GB ~10 min. Acceptable. |

---

## 6. Hors scope

- **OCR distribué / multi-node** : pas besoin pour le volume actuel.
- **MinerU** : moteur alternatif rejeté au brainstorming (Docling choisi pour CPU-out-of-the-box + formats supplémentaires).
- **GPU pour Docling** : VRAM saturée par qwen3-embedding + qwen3-reranker sur k8s-3.
- **Migration hors-PG** : la fiabilité PR #4682 est préservée.
- **Auto-scaling HPA** : volume stable, pas de bénéfice.
- **Backoff / retry LightRAG → Docling** : géré par LightRAG upstream (poll loop).
- **Métriques Prometheus / dashboards** : différé — voir §4.
- **Re-indexation des anciens docs** : action utilisateur via UI (comme pour PR #4682).

---

## 7. Décisions architecturales à valider

| # | Décision | Alternatives écartées | Justification |
|---|---|---|---|
| D1 | Docling vs MinerU | MinerU | Docling CPU out-of-the-box + formats (md/html/xhtml/tiff) + équations LaTeX + moins de knobs de tuning. MinerU nécessite plus de config pour qualité équivalente. |
| D2 | Service séparé vs Docling in-process | In-process (LibreDocling via `pip install docling`) | Service réutilisable + parallélisme multi-doc + découplage cycle de vie + observable indépendamment. Coût marginal d'un pod de plus. |
| D3 | Pas de GPU | GPU sur k8s-3 | VRAM saturée par qwen3-embed + qwen3-reranker ; Docling CPU est viable pour le volume. |
| D4 | Pas d'auth (API key) sur Docling | Auth avec clé partagée | LightRAG upstream ne supporte pas l'envoi d'`X-Api-Key`. Isolation réseau via ClusterIP + pas de route suffit. |
| D5 | bjw-s app-template chart | Chart custom | Cohérence avec `lightrag` (même chart, mêmes patterns). Évite la dette de maintenance d'un chart maison. |
| D6 | Pas de backup du cache modèles | kopiur backup | Cache régénérable, re-téléchargement ~10 min acceptable. Évite ~5 GB de backups quotidiens pour un bénéfice marginal. |
| D7 | `DOCLING_FORCE_OCR=false` | `true` | Documents mixtes (texte natif + scans) : on évite l'OCR inutile sur les pages déjà textuelles (gain perf ×3 sur contrats). |
| D8 | `MAX_PARALLEL_PARSE_DOCLING=2` | Default 1 | Volume 50–500 docs ; on accepte la concurrence modérée pour réduire le temps total d'indexation. |

---

## 8. Critères d'acceptation

1. **Docling-serve déployé** : `kubectl get pods -n ai -l app.kubernetes.io/name=docling-serve` → 1/1 Running.
2. **LightRAG configuré** : `kubectl logs -n ai deploy/lightrag --since=2m | grep -i "PDF.*docling\|parser.*enabled"` → confirme parser configuré.
3. **PDF scanné indexé end-to-end** :
   - Upload via UI d'un PDF scanné de test (≥ 1 page image).
   - `kubectl exec -n ai lightrag-1 -c postgres -- psql -U postgres -d lightrag -tA -c "select count(*) from lightrag_vdb_chunks_qwen3_embedding_0_6b_1024d where workspace_id='lightrag' and content ilike '%<mot_unique_du_test>%'"` → > 0 (texte extrait présent).
4. **PDF natif toujours fonctionnel** : upload d'un PDF textuel (sans scan) → toujours indexé via règle `*:native-teP` (pas de régression).
5. **Pas de régression post-PR #4682** :
   - Logs LightRAG : `Reranking is enabled`, role-split LLM, PG storages, query_prefix générique — tous identiques.
   - 0 erreur `NanoVectorDB`, `flush failed`, `Traceback` sur la fenêtre post-déploiement.
6. **Ressources tenues** : `kubectl top pod -n ai -l app.kubernetes.io/name=docling-serve` → CPU < 4, MEM < 8Gi en régime stable.

---

## 9. Fichiers à créer / modifier

### Création (nouveau subsystem)

```
kubernetes/apps/ai/docling-serve/
├── ks.yaml                                    # Flux Kustomization
└── app/
    ├── ocirepository.yaml                     # app-template chart 5.2.1
    ├── pvc.yaml                               # PVC docling-models
    ├── helmrelease.yaml                       # Deployment + Service + values
    └── kustomization.yaml                     # namespace: ai, resources list
```

### Modification

```
kubernetes/apps/ai/lightrag/app/helmrelease.yaml
  + env.LIGHTRAG_PARSER = "pdf:docling,*:native-teP,*:legacy-R"
  + env.DOCLING_ENDPOINT = "http://docling-serve.ai.svc.cluster.local:5001"
  + env.DOCLING_DO_OCR = "true"
  + env.DOCLING_FORCE_OCR = "false"
  + env.MAX_PARALLEL_PARSE_DOCLING = "2"
  + env.DOCLING_TIMEOUT = "300"
```

### Documentation

```
docs/superpowers/specs/2026-09-29-lightrag-ocr-design.md    # ce fichier
docs/superpowers/plans/2026-09-29-lightrag-ocr.md            # plan d'implémentation
```
