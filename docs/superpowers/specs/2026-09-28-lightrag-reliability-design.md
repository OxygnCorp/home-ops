# LightRAG — Fiabilisation de l'indexation et du retrieval

**Date** : 2026-09-28
**Statut** : approuvé (design en conversation)
**Périmètre** : `kubernetes/apps/ai/lightrag/` (app + ks), `kubernetes/apps/ai/litellm/` (modèles + routeur), ajout d'un cluster CNPG via `kubernetes/components/postgres`
**Hors périmètre** : OCR des PDF scannés ; upgrade LightRAG (déjà `v1.5.7`) ; memini et les modèles GPU

## Contexte

### Symptômes rapportés
- Documents marqués `failed` par l'indexation.
- Indexation extrêmement lente / timeouts.
- Perte de données / index corrompu.
- Qualité d'extraction médiocre.

### Diagnostic (relevé en cluster le 2026-09-28)

Coupable principal identifié dans les logs et le stockage :

- Document `2024-04-23_Offre prêt BNP signée.pdf` en `status: failed`, `error_msg` :
  `NanoVectorDBStorage[entities] index flush failed: 'list' object has no attribute 'data'`.
- Index vecteurs vidés : `vdb_chunks.json` et `vdb_relationships.json` =
  `{"embedding_dim": 1024, "data": [], "matrix": ""}` (49 octets) alors que le graphe contient
  638 nœuds / 933 arêtes et que `kv_store_text_chunks.json` pèse 265 Ko. → chunks et relations
  ne sont plus retrouvables par similarité.
- Stockages = défauts LightRAG (`JsonKVStorage`, `JsonDocStatusStorage`, `NetworkXStorage`,
  `NanoVectorDBStorage`), que la doc upstream qualifie explicitement de
  *« suitable only for small-scale testing… not suitable for production »*.
- Config au démarrage : `Reranking is disabled` ;
  `query_prefix='Instruct: Given a user message, retrieve relevant past memories\nQuery: '`
  (instruction copiée de memini, inadaptée au retrieval documentaire).
- Concurrence très basse : `MAX_ASYNC_LLM=2`, `EMBEDDING_FUNC_MAX_ASYNC=1`,
  `EMBEDDING_BATCH_NUM=4` ; LLM d'extraction = `MiniMax-M3` (flagship).
- GPU k8s-3 : `nvidia-smi` **3001 / 4096 MiB déjà utilisés au repos** (~1 Go libre) ;
  consommateurs = `qwen3-embedding-0.6b` + `qwen3-reranker-0.6b`
  (`mcp-tools-embedding` est en **CPU**, non concerné).
- Corpus : ~50–500 documents, majoritairement **français** (PDF texte, PDF scannés, Markdown,
  Office, HTML) ; OCR optionnel.

### Objectif
Rendre l'indexation **fiable** (fin des FAILED et de la perte d'index) et **plus rapide**, améliorer
le retrieval, **sans ajouter de modèle GPU** (VRAM insuffisante).

## Décisions

1. **Stockage → PostgreSQL/pgvector**, backend recommandé par LightRAG pour la production, via le
   composant CNPG existant `components/postgres`. L'extension `vector` est déclarée par un CR
   `Database` (pgvector n'étant pas une extension « trusted », un rôle applicatif ne peut pas
   `CREATE EXTENSION` ; l'opérateur CNPG le fait en superuser).
2. **Embedding : conserver `qwen3-embedding-0.6b`.** Il surpasse `bge-m3` à taille égale
   (MTEB multilingue 64,33 vs 59,56 ; contexte 32k vs 8k ; licence Apache-2.0) et est déjà résident.
   On corrige le `EMBEDDING_QUERY_PREFIX` et on augmente le débit. Aucune instance dédiée
   (VRAM insuffisante), donc pas de re-embed memini.
3. **LLM par rôle** (recommandation LightRAG : ≥ 32 B, ≥ 32 k de contexte, *éviter les modèles de
   raisonnement à l'indexation*, modèle plus fort en requête) :
   - extraction + mots-clés → **`dsv41f`** (deepseek-v4.1-flash : rapide, cache-entrée bon marché) ;
   - requête → **`MiniMax-M3`** (qualité) ;
   - fallback routeur litellm ajouté pour le modèle d'extraction.
4. **Reranker activé** : `qwen3-reranker-0.6b` via litellm (la doc LightRAG indique que le rerank
   améliore significativement le retrieval et recommande le mode `mix`).
5. **Parsing/chunking** : parseur natif pour les formats texte, `CHUNK_SIZE` porté à 1000.
6. **Repartir de zéro** : l'index actuel (corrompu) est jeté ; les sources sont ré-indexées.
7. **OCR hors périmètre** (optionnel) — phase ultérieure via docling-serve/MinerU si le besoin
   se confirme.

## Design

### 1. Stockage PostgreSQL/pgvector

Fichiers :

- **`kubernetes/apps/ai/lightrag/ks.yaml`**
  - ajouter le label `components.postgres/cnpg: init` (cluster net-neuf, pas de recovery Barman) ;
  - ajouter `../../../../components/postgres` à `spec.components` ;
  - ajouter à `spec.healthCheckExprs` l'entrée `postgresql.cnpg.io/v1 Cluster` (copiée de
    `kubernetes/apps/ai/litellm/ks.yaml`).

- **`kubernetes/apps/ai/lightrag/app/database.yaml`** (nouveau) — déclare l'extension `vector` :

  ```yaml
  ---
  apiVersion: postgresql.cnpg.io/v1
  kind: Database
  metadata:
    name: lightrag
  spec:
    name: lightrag
    owner: lightrag
    cluster:
      name: lightrag
    extensions:
      - name: vector
        ensure: present
  ```

- **`kubernetes/apps/ai/lightrag/app/kustomization.yaml`** : ajouter `./database.yaml`.

- **`kubernetes/apps/ai/lightrag/app/helmrelease.yaml`** (env du conteneur `app`) :

  ```yaml
  LIGHTRAG_KV_STORAGE: PGKVStorage
  LIGHTRAG_VECTOR_STORAGE: PGVectorStorage
  LIGHTRAG_GRAPH_STORAGE: PGTableGraphStorage      # tables standard, sans Apache AGE
  LIGHTRAG_DOC_STATUS_STORAGE: PGDocStatusStorage
  POSTGRES_HOST: lightrag-rw
  POSTGRES_WORKSPACE: lightrag
  POSTGRES_PORT:     # secretKeyRef lightrag-app/port
  POSTGRES_USER:     # secretKeyRef lightrag-app/username
  POSTGRES_PASSWORD: # secretKeyRef lightrag-app/password
  POSTGRES_DATABASE: # secretKeyRef lightrag-app/dbname
  ```

Résultat : transactions ACID, reprise propre après crash, fin de `NanoVectorDBStorage`.

Notes :
- `PGTableGraphStorage` est retenu (et non `PGGraphStorage`) car l'image CNPG standard n'embarque
  pas Apache AGE.
- Le composant `postgres` crée le Cluster `${APP}` (`lightrag`), le Secret `lightrag-app` et les
  sauvegardes Barman. Le label `cnpg: init` est à retirer après la première sauvegarde planifiée.
- Le pod LightRAG peut boucler tant que le Cluster / l'extension ne sont pas prêts ; les retries
  HelmRelease (`install.strategy: RetryOnFailure`, défauts `cluster-apps`) couvrent le cas.
  Un initContainer d'attente est une option si la boucle s'avère gênante.

### 2. Multiplexage des modèles LLM

- **`kubernetes/apps/ai/litellm/app/models/dsv41f-nothink.yaml`** (nouveau) : copie de `dsv41f`
  avec `additional: { reasoning_effort: none }` (désactive le raisonnement à l'indexation, par
  symétrie avec `dsv41f-max` qui pinne `max`). À ajouter dans `models/kustomization.yaml`.
- **`kubernetes/apps/ai/litellm/app/litellmproxy.yaml`** → `routerSettings.fallbacks` :
  `dsv41f-nothink: [go-glm-5.3-flash, MiniMax-M3]`.
- **`kubernetes/apps/ai/lightrag/app/helmrelease.yaml`** :

  ```yaml
  LLM_MODEL: MiniMax-M3               # défaut conservé
  EXTRACT_LLM_MODEL: dsv41f-nothink
  KEYWORD_LLM_MODEL: dsv41f-nothink
  QUERY_LLM_MODEL: MiniMax-M3
  MAX_ASYNC_LLM: "4"
  ENTITY_EXTRACTION_USE_JSON: "true"
  SUMMARY_LANGUAGE: French
  ```

### 3. Embedding & reranker

Dans `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` :

```yaml
# préfixe générique de retrieval (remplace l'instruction "past memories" de memini)
EMBEDDING_QUERY_PREFIX: "Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery: "
# débit (le GPU reste le plafond ; ces réglages évitent les allers-retours inutiles)
EMBEDDING_BATCH_NUM: "16"
EMBEDDING_FUNC_MAX_ASYNC: "2"
# reranker via litellm
RERANK_BINDING: cohere
RERANK_BINDING_HOST: http://litellm.ai:4000
RERANK_MODEL: qwen3-reranker-0.6b
RERANK_BINDING_API_KEY:  # secretKeyRef lightrag-secret/EMBEDDING_BINDING_API_KEY
```

`EMBEDDING_MODEL`, `EMBEDDING_DIM`, `EMBEDDING_ASYMMETRIC`, `EMBEDDING_DOCUMENT_PREFIX` et
`EMBEDDING_TOKEN_LIMIT` restent inchangés. Mode de requête : `mix` (défaut LightRAG).

### 4. Parsing & chunking

```yaml
LIGHTRAG_PARSER: "*:native-teP,*:legacy-R"
CHUNK_SIZE: "1000"
CHUNK_OVERLAP_SIZE: "100"
```

Les PDF scannés sans couche texte ne sont pas lisibles (OCR hors périmètre).

### 5. Runtime & exploitation

- **`helmrelease.yaml`** : `resources.limits.memory: 2Gi` (requests inchangées : `100m` / `512Mi`).
- PVC `lightrag` conservé (`inputs/`, `tiktoken`) ; backup kopiur conservé.
- Reprise à zéro : vider `WORKING_DIR` (`/app/data/rag_storage`) et ré-indexer les sources.

## Risques & rollback

- **Noms exacts des variables** (`POSTGRES_*`, `*_LLM_MODEL`, `RERANK_*`, `LIGHTRAG_*_STORAGE`) :
  à confirmer au plan en lisant l'`env.example` complet de la `v1.5.7`.
- **Ordre de démarrage** : boucle possible du pod avant que le Cluster et l'extension `vector`
  soient prêts (résolu par les retries).
- **`dsv41f` raisonnement** : le défaut sans paramètre n'est pas documenté ; l'alias `-nothink`
  évite toute surprise. À valider par un appel de test.
- **`PGTableGraphStorage`** est moins performant que Neo4j en très grande échelle (dixit la doc),
  mais suffisant pour ~50–500 documents et évite une brique supplémentaire.
- **Rollback** : revert de la PR. Le cluster CNPG `lightrag` est un ajout isolé, supprimable.
  L'index fichier d'origine n'est pas conservé (wipe assumé).

## Hors scope

- OCR des PDF scannés (docling-serve / MinerU).
- Upgrade LightRAG (déjà `v1.5.7`).
- Nouveau modèle GPU / instance d'embedding dédiée (VRAM insuffisante).
- memini (partage `qwen3-embedding-0.6b` mais aucun re-embed nécessaire).

## Validation

- **Par PR** : `mise exec -- flate test ks --path ./kubernetes/apps/ai/lightrag` +
  `mise exec -- flate test hr --path ./kubernetes/apps/ai/lightrag` (et litellm), puis konflate.
- **Post-merge** :
  - Cluster CNPG `lightrag` Ready (3/3) ; extension présente (`\dx` → `vector`) ; Secret
    `lightrag-app` synchronisé.
  - LightRAG : log de démarrage montrant les stockages `PG*`, `Reranking` actif, `query_prefix`
    générique ; tables créées dans Postgres.
  - Indexation d'un document témoin : passe en `PROCESSED` sans `error_msg`, vecteurs non vides
    (`SELECT count(*) FROM lightrag_vdb_chunks` > 0).
  - Requête `mix` avec rerank : réponse pertinente.
