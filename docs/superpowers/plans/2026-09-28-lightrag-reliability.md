# LightRAG — Fiabilisation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Basculer LightRAG sur un stockage PostgreSQL/pgvector, corriger l'embedding/reranker et router les modèles LLM par rôle, pour rendre l'indexation fiable et plus rapide.

**Architecture:** Un cluster CloudNativePG `lightrag` (composant partagé `components/postgres`, extension `vector` via un CR `Database`) remplace les stockages fichiers JSON/Nano/NetworkX. Côté LiteLLM on ajoute un alias `dsv41f-nothink` (raisonnement coupé) + une chaîne de fallback ; côté LightRAG on route `EXTRACT`/`KEYWORD` sur cet alias, `QUERY` sur `MiniMax-M3`, on corrige le préfixe d'embedding et on active le reranker. Flux applique après merge ; l'index corrompu est jeté et les sources ré-indexées.

**Tech Stack:** kustomize/HelmRelease (Flux), CloudNativePG (opérateur `database/cloudnative-pg`), LiteLLM (CRs `LiteLLMModel`/`LiteLLMProxy`), `flate` (validation locale), `gh` (PR).

**Spec:** [2026-09-28-lightrag-reliability-design.md](../specs/2026-09-28-lightrag-reliability-design.md)

## Global Constraints

- LightRAG reste en `ghcr.io/hkuds/lightrag:v1.5.7` — aucun upgrade d'image.
- Embedding inchangé : `qwen3-embedding-0.6b`, `EMBEDDING_DIM=1024`, `EMBEDDING_TOKEN_LIMIT=1800`, `EMBEDDING_DOCUMENT_PREFIX=NO_PREFIX`. Aucun re-embed de memini.
- Stockages cibles : `PGKVStorage`, `PGVectorStorage`, `PGTableGraphStorage`, `PGDocStatusStorage` ; `POSTGRES_WORKSPACE=lightrag`.
- Modèles : `EXTRACT_LLM_MODEL=KEYWORD_LLM_MODEL=dsv41f-nothink`, `QUERY_LLM_MODEL=MiniMax-M3`, `LLM_MODEL=MiniMax-M3`.
- `MAX_ASYNC_LLM=4`, `ENTITY_EXTRACTION_USE_JSON=true`, `SUMMARY_LANGUAGE=French`.
- `CHUNK_SIZE=1000`, `CHUNK_OVERLAP_SIZE=100`, `LIGHTRAG_PARSER=*:native-teP,*:legacy-R`.
- `resources.limits.memory=2Gi` sur le conteneur `app` (requests inchangées `cpu 100m` / `memory 512Mi`).
- OCR hors périmètre ; aucun nouveau modèle GPU.

## Review Focus

- **Variables de stockage silencieusement ignorées** : si un nom de variable `LIGHTRAG_*_STORAGE`/`POSTGRES_*` est erroné, LightRAG retombe sur les stockages fichiers sans erreur. Test : le log de démarrage doit lister explicitement les stockages `PG*` (Task 5, Step 1).
- **Extension `vector` absente** : `PGVectorStorage` échoue à l'init si l'opérateur n'a pas encore créé l'extension. Test : `select extname from pg_extension` contient `vector` (Task 5, Step 1) avant toute ré-indexation.
- **Raisonnement `dsv41f` non coupé** : l'extraction serait lente et le JSON moins fiable. Test : l'alias `dsv41f-nothink` répond sans bloc de raisonnement (Task 1, Step 3 / Task 5, Step 2).
- **Reranker inactif ou 4xx** : un driver mal choisi laisse le rerank silencieusement désactivé. Test : le log de démarrage de LightRAG n'affiche plus `Reranking is disabled` (Task 5, Step 1).
- **Données orphelines / workspace double** : l'ancien index fichier est abandonné ; s'assurer qu'un seul `POSTGRES_WORKSPACE` est utilisé et que les tables vecteurs se remplissent. Test : comptage non nul dans les tables `*_vdb_*` après un document témoin (Task 5, Step 3).

---

### Task 1: LiteLLM — alias `dsv41f-nothink` + chaîne de fallback

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/models/dsv41f-nothink.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/models/kustomization.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml` (`spec.routerSettings.fallbacks`)
- Test: `flate test hr` sur litellm

**Interfaces:**
- Consumes: néant.
- Produces: nom de modèle LiteLLM `dsv41f-nothink` (consommé par Task 3) et entrée de fallback `dsv41f-nothink → go-glm-5.3-flash → MiniMax-M3`.

- [ ] **Step 1: Créer le modèle `dsv41f-nothink`**

Créer `kubernetes/apps/ai/litellm/app/models/dsv41f-nothink.yaml` (copie de `dsv41f.yaml` + raisonnement coupé, sur le modèle de `dsv41f-max.yaml`) :

```yaml
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMModel
metadata:
  name: dsv41f-nothink
spec:
  modelName: dsv41f-nothink
  proxyRef: litellm
  params:
    model: openai/deepseek-v4.1-flash
    apiBase: https://opencode.ai/zen/go/v1
    apiKey: os.environ/OPENCODE_API_KEY
    # Same upstream as dsv41f, with reasoning disabled: LightRAG's indexing
    # guidance says to avoid reasoning models during extraction. OpenCode Go
    # honours reasoning_effort (none disables reasoning), same as dsv41f-max/max.
    additional:
      reasoning_effort: none
  info:
    mode: chat
    maxInputTokens: 1000000
    maxOutputTokens: 384000
    supportsFunctionCalling: true
    supportsVision: true
    supportsPromptCaching: true
```

- [ ] **Step 2: Enregistrer le modèle et ajouter le fallback**

Dans `kubernetes/apps/ai/litellm/app/models/kustomization.yaml`, ajouter après `- ./dsv41f-max.yaml` :

```yaml
  - ./dsv41f-nothink.yaml
```

Dans `kubernetes/apps/ai/litellm/app/litellmproxy.yaml`, sous `spec.routerSettings.fallbacks`, ajouter une entrée :

```yaml
      - dsv41f-nothink:
          - go-glm-5.3-flash
          - MiniMax-M3
```

- [ ] **Step 3: Valider et vérifier le raisonnement coupé**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm`
Expected: succès (CRs rendus sans erreur schéma/références).

Après déploiement (Task 5 ou reconcile manuel), test bout-en-bout du modèle :

```bash
KEY=$(kubectl get secret -n ai litellm-secret -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d)
kubectl run -n ai llm-probe --rm -i --restart=Never --image=curlimages/curl -- \
  curl -s http://litellm.ai:4000/v1/chat/completions \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d '{"model":"dsv41f-nothink","messages":[{"role":"user","content":"Réponds uniquement: OK"}],"max_tokens":8}'
```

Expected: réponse `200` avec un contenu court (`OK`), sans bloc de raisonnement.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/ai/litellm/app/models/dsv41f-nothink.yaml \
        kubernetes/apps/ai/litellm/app/models/kustomization.yaml \
        kubernetes/apps/ai/litellm/app/litellmproxy.yaml
git commit -m "feat(litellm): add dsv41f-nothink alias and indexing fallback chain"
```

### Task 2: LightRAG — stockage PostgreSQL/pgvector

**Files:**
- Modify: `kubernetes/apps/ai/lightrag/ks.yaml`
- Create: `kubernetes/apps/ai/lightrag/app/database.yaml`
- Modify: `kubernetes/apps/ai/lightrag/app/kustomization.yaml`
- Modify: `kubernetes/apps/ai/lightrag/app/helmrelease.yaml` (env de stockage)
- Test: `flate test ks` + `flate test hr` sur lightrag

**Interfaces:**
- Consumes: composant `kubernetes/components/postgres` (Label `components.postgres/cnpg=init`).
- Produces: Secret CNPG `lightrag-app` (keys `port`/`username`/`password`/`dbname`), extension `vector` présente, variables `LIGHTRAG_*_STORAGE`/`POSTGRES_*` sur le conteneur `app`.

- [ ] **Step 1: Confirmer les noms exacts des variables**

Run (source 1 : l'image en cours ; source 2 : le tag upstream si le fichier n'est pas présent) :

```bash
kubectl exec -n ai deploy/lightrag -- sh -c 'find / -name "env.example" 2>/dev/null | head; cat /app/env.example 2>/dev/null | grep -E "STORAGE|POSTGRES|WORKSPACE|RERANK_BINDING|_LLM_MODEL"'
# fallback (hors cluster) :
curl -fsSL https://raw.githubusercontent.com/HKUDS/LightRAG/v1.5.7/env.example | grep -E "STORAGE|POSTGRES|WORKSPACE|RERANK_BINDING|_LLM_MODEL"
```

Expected: confirmer `LIGHTRAG_KV_STORAGE`, `LIGHTRAG_VECTOR_STORAGE`, `LIGHTRAG_GRAPH_STORAGE`, `LIGHTRAG_DOC_STATUS_STORAGE`, `POSTGRES_HOST/PORT/USER/PASSWORD/DATABASE/WORKSPACE`, `EXTRACT_LLM_MODEL`, `KEYWORD_LLM_MODEL`, `QUERY_LLM_MODEL`, `RERANK_BINDING*`. Si un nom diffère, utiliser le nom réel de `env.example` (il fait foi) et le reporter dans ce plan.

- [ ] **Step 2: Créer le CR `Database` (extension `vector`)**

Créer `kubernetes/apps/ai/lightrag/app/database.yaml` :

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

- [ ] **Step 3: Brancher le composant postgres dans le `ks.yaml`**

Dans `kubernetes/apps/ai/lightrag/ks.yaml` :

a. Ajouter le label (cluster net-neuf, pas de recovery Barman) :

```yaml
metadata:
  name: lightrag
  labels:
    components.postgres/cnpg: init
```

b. Ajouter le composant dans `spec.components` :

```yaml
  components:
    - ../../../../components/postgres
    - ../../../../components/kopiur/backup
```

c. Ajouter la santé du Cluster CNPG (copie de `kubernetes/apps/ai/litellm/ks.yaml:23-26`) :

```yaml
  healthCheckExprs:
    - apiVersion: postgresql.cnpg.io/v1
      kind: Cluster
      failed: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'False')
      current: status.conditions.filter(e, e.type == 'Ready').all(e, e.status == 'True')
```

- [ ] **Step 4: Déclarer `database.yaml` dans kustomize**

Dans `kubernetes/apps/ai/lightrag/app/kustomization.yaml`, ajouter :

```yaml
  - ./database.yaml
```

- [ ] **Step 5: Basculer les stockages et la connexion Postgres dans le HelmRelease**

Dans `kubernetes/apps/ai/lightrag/app/helmrelease.yaml`, sous `controllers.lightrag.containers.app.env`, remplacer la section « Server » (lignes `HOST`…`CHUNK_SIZE`) en insérant les variables de stockage après `CHUNK_SIZE` (Task 3 ajustera `CHUNK_SIZE`) :

```yaml
              # Storage — production backend: PostgreSQL (pgvector for vectors,
              # plain-table graph, no Apache AGE). Replaces the file-based
              # Json/Nano/NetworkX defaults, which upstream marks test-only.
              LIGHTRAG_KV_STORAGE: PGKVStorage
              LIGHTRAG_VECTOR_STORAGE: PGVectorStorage
              LIGHTRAG_GRAPH_STORAGE: PGTableGraphStorage
              LIGHTRAG_DOC_STATUS_STORAGE: PGDocStatusStorage
              POSTGRES_HOST: lightrag-rw
              POSTGRES_WORKSPACE: lightrag
              POSTGRES_PORT:
                valueFrom:
                  secretKeyRef:
                    name: lightrag-app
                    key: port
              POSTGRES_USER:
                valueFrom:
                  secretKeyRef:
                    name: lightrag-app
                    key: username
              POSTGRES_PASSWORD:
                valueFrom:
                  secretKeyRef:
                    name: lightrag-app
                    key: password
              POSTGRES_DATABASE:
                valueFrom:
                  secretKeyRef:
                    name: lightrag-app
                    key: dbname
```

- [ ] **Step 6: Valider et commit**

Run:

```bash
mise exec -- flate test ks --path ./kubernetes/apps/ai/lightrag
mise exec -- flate test hr --path ./kubernetes/apps/ai/lightrag
```

Expected: succès des deux commandes (le composant postgres rend le Cluster + le Secret `lightrag-app` attendus ; le HelmRelease rend les nouvelles variables).

```bash
git add kubernetes/apps/ai/lightrag/ks.yaml \
        kubernetes/apps/ai/lightrag/app/database.yaml \
        kubernetes/apps/ai/lightrag/app/kustomization.yaml \
        kubernetes/apps/ai/lightrag/app/helmrelease.yaml
git commit -m "feat(lightrag): move storage to PostgreSQL/pgvector via cnpg component"
```

### Task 3: LightRAG — modèles par rôle, embedding, reranker, parsing

**Files:**
- Modify: `kubernetes/apps/ai/lightrag/app/helmrelease.yaml`
- Test: `flate test hr` sur lightrag

**Interfaces:**
- Consumes: modèle LiteLLM `dsv41f-nothink` (Task 1), modèle `qwen3-reranker-0.6b` (déjà déployé).
- Produces: env final du conteneur `app` (routage LLM par rôle, embedding/rerank, parsing, limite mémoire).

- [ ] **Step 1: Router les LLM par rôle et régler l'extraction**

Dans `kubernetes/apps/ai/lightrag/app/helmrelease.yaml`, remplacer la ligne `LLM_MODEL: MiniMax-M3` et la ligne `MAX_ASYNC_LLM: "2"` par :

```yaml
              LLM_BINDING: openai
              LLM_BINDING_HOST: http://litellm.ai.svc.cluster.local:4000/v1
              LLM_MODEL: MiniMax-M3
              # Indexing (high volume): fast, cheap-cache model, reasoning off.
              EXTRACT_LLM_MODEL: dsv41f-nothink
              KEYWORD_LLM_MODEL: dsv41f-nothink
              # Query (low volume, quality-critical).
              QUERY_LLM_MODEL: MiniMax-M3
              MAX_ASYNC_LLM: "4"
              LLM_TIMEOUT: "480"
              ENTITY_EXTRACTION_USE_JSON: "true"
              SUMMARY_LANGUAGE: French
```

- [ ] **Step 2: Chunking et parseur**

Dans le même fichier, remplacer `CHUNK_SIZE: "800"` par :

```yaml
              CHUNK_SIZE: "1000"
              CHUNK_OVERLAP_SIZE: "100"
              LIGHTRAG_PARSER: "*:native-teP,*:legacy-R"
```

- [ ] **Step 3: Corriger le préfixe d'embedding et augmenter le débit**

Remplacer la ligne `EMBEDDING_QUERY_PREFIX` par un préfixe de retrieval générique, et augmenter les réglages de débit :

```yaml
              EMBEDDING_QUERY_PREFIX: "Instruct: Given a search query, retrieve relevant passages that answer the query\nQuery: "
              EMBEDDING_BATCH_NUM: "16"
              EMBEDDING_FUNC_MAX_ASYNC: "2"
```

(`EMBEDDING_DOCUMENT_PREFIX: "NO_PREFIX"`, `EMBEDDING_ASYMMETRIC`, `EMBEDDING_DIM`, `EMBEDDING_TOKEN_LIMIT` restent inchangés.)

- [ ] **Step 4: Activer le reranker**

Après le bloc `EMBEDDING_TIMEOUT: "120"`, ajouter :

```yaml
              # Reranker via litellm (Cohere-compatible /v1/rerank).
              RERANK_BINDING: cohere
              RERANK_BINDING_HOST: http://litellm.ai:4000
              RERANK_MODEL: qwen3-reranker-0.6b
              RERANK_BINDING_API_KEY:
                valueFrom:
                  secretKeyRef:
                    name: lightrag-secret
                    key: EMBEDDING_BINDING_API_KEY
```

- [ ] **Step 5: Ajouter une limite mémoire**

Dans `controllers.lightrag.containers.app.resources`, ajouter un bloc `limits` sous `requests` :

```yaml
            resources:
              requests:
                cpu: 100m
                memory: 512Mi
              limits:
                memory: 2Gi
```

- [ ] **Step 6: Valider et commit**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/lightrag`
Expected: succès (HelmRelease rendu sans erreur schéma).

```bash
git add kubernetes/apps/ai/lightrag/app/helmrelease.yaml
git commit -m "feat(lightrag): role-split LLM models, fix embedding prefix, enable reranker"
```

### Task 4: Pousser et créer la PR

**Files:**
- Aucun (git + gh).

**Interfaces:**
- Consumes: commits des Tasks 1–3 sur `feat/lightrag-reliability`.
- Produces: PR ouverte, checks CI (image-pull) + konflate (rendered diff).

- [ ] **Step 1: Diff local contre `origin/main`**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff ks --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
mise exec -- flate diff hr --path ./kubernetes/apps --path-orig /tmp/baseline/kubernetes/apps
git worktree remove /tmp/baseline --force
```

Expected: le diff rendu montre, côté lightrag, l'ajout du Cluster `lightrag` + Secret `lightrag-app` + CR `Database`, les variables de stockage PG, les modèles par rôle, le rerank et la limite mémoire ; côté litellm, le CR `dsv41f-nothink` et le fallback.

- [ ] **Step 2: Push et création de la PR**

```bash
git push -u origin feat/lightrag-reliability
gh pr create --fill --body "Spec: docs/superpowers/specs/2026-09-28-lightrag-reliability-design.md — bascule LightRAG sur PostgreSQL/pgvector (fiabilité), modèles LLM par rôle + reranker, ré-indexation à zéro."
```

Expected: URL de PR retournée.

- [ ] **Step 3: Vérifier les checks**

Run: `gh pr checks --watch`
Expected: checks CI + konflate au vert ; le commentaire konflate montre le diff rendu décrit au Step 1.

- [ ] **Step 4: Merge (après revue humaine)**

```bash
gh pr merge --merge
```

### Task 5: Validation post-merge (cluster + ré-indexation)

**Files:**
- Aucun (inspection cluster + action de ré-indexation).

**Interfaces:**
- Consumes: PR mergée → Flux reconcile ; Secret `lightrag-app` ; extension `vector`.

- [ ] **Step 1: Vérifier le cluster CNPG, l'extension et la config LightRAG**

```bash
kubectl get cluster -n ai lightrag
kubectl get pods -n ai -l cnpg.io/cluster=lightrag
kubectl exec -n ai lightrag-1 -c postgres -- psql -U postgres -d lightrag -c '\dx'
kubectl logs -n ai deploy/lightrag --since=5m | grep -iE "storage|rerank|query_prefix|embedding config"
```

Expected: Cluster `lightrag` Ready (3/3) ; `\dx` liste l'extension `vector` ; les logs LightRAG listent `PGKVStorage`/`PGVectorStorage`/`PGTableGraphStorage`/`PGDocStatusStorage`, ne disent **plus** `Reranking is disabled`, et affichent le nouveau `query_prefix`.

- [ ] **Step 2: Vérifier que l'indexation n'utilise plus NanoVectorDB et que le rerank répond**

```bash
kubectl logs -n ai deploy/lightrag --since=30m | grep -iE "NanoVectorDB|flush failed|error" | tail -20
kubectl exec -n ai lightrag-1 -c postgres -- psql -U postgres -d lightrag -c '\dt'
```

Expected: aucune occurrence de `NanoVectorDBStorage` / `flush failed` ; `\dt` montre les tables LightRAG (KV, doc status, vecteurs, graphe) sous le workspace `lightrag`.

- [ ] **Step 3: Ré-indexer les sources et vérifier que les vecteurs se remplissent**

Ré-uploader les documents sources via l'UI (`https://lightrag.oxygn.dev`) ou l'API MCP `lightrag`, puis :

```bash
kubectl exec -n ai lightrag-1 -c postgres -- psql -U postgres -d lightrag -c \
  "select (select count(*) from lightrag_vdb_chunks) as chunks, (select count(*) from lightrag_vdb_entity) as entities;"
kubectl logs -n ai deploy/lightrag --since=15m | grep -iE "processed|failed" | tail -20
```

Expected: `chunks`/`entities` non nuls (adapté le nom des tables au résultat du `\dt` du Step 2) ; les documents passent en `processed`, aucun `failed`.

- [ ] **Step 4: Nettoyer l'ancien index fichier (optionnel) et le label `cnpg: init`**

```bash
kubectl exec -n ai deploy/lightrag -- sh -c 'rm -rf /app/data/rag_storage/*'
```

Expected: les fichiers `vdb_*`/`kv_store_*`/`graph_*` de l'ancien index sont supprimés (inertes depuis le basculement PG). Ne retirer le label `components.postgres/cnpg: init` du `ks.yaml` **qu'après la première Sauvegarde planifiée** (dimanche 01:30) — hors de cette PR, via une PR de suivi.
