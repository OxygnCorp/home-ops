# Migration toolhive → LiteLLM MCP Gateway — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remplacer toolhive (runner + gateway MCP) par le couple litellm-operator (`LiteLLMMCPServer`) + proxy litellm `/mcp`, avec 2 LiteLLMTeam (mcp-apps / mcp-devops), tool search intégré, et retrait complet de toolhive.

**Architecture:** Les 15 serveurs MCP actuels sont recréés comme `LiteLLMMCPServer` (3 modes : remote `spec.url`, workload HTTP natif, workload stdio wrappé HTTP via supergateway/mcp-proxy) dans `kubernetes/apps/ai/litellm/app/mcp/`. Les RBAC et ServiceAccounts existants (flux, kubectl, talos) sont déplacés tels quels. L'authZ passe par 2 `LiteLLMTeam` référencés par `teamID` sur les `LiteLLMVirtualKey` existants. La découverte de tools passe de `find_tool`/`call_tool` (catalogue dynamique toolhive + EmbeddingServer TEI) aux tools virtuels litellm `mcp_tool_search`/`mcp_tool_call` (recherche keyword token-overlap intégrée, aucun embedding model requis). Cut-over des 3 agents un par un, teardown toolhive en dernier ; rollback = git revert (Flux recrée tout).

**Tech Stack:** Flux Kustomization, litellm-operator home-operations v0.0.20 (CRDs déjà installés), litellm v1.103.2 (mcp_tool_search nécessite ≥ v1.92 — OK), external-secrets/1Password, Gateway API.

**Spec:** ce document est autonome — contexte : verdict du spike + inventaire phase 0 du 2026-10-03 (gateways toolhive en mode catalogue dynamique find_tool/call_tool ; qwen3-embedding TEI déjà déployé pour un usage /v1/responses futur).

4 PRs : PR 1 (serveurs MCP, additif, zéro rupture) → PR 2 (authZ équipes + tool search) → PR 3 (cut-over agents) → PR 4 (teardown toolhive).

## Global Constraints

- litellm image reste `ghcr.io/berriai/litellm-database:v1.103.2@sha256:bf6d8e366f41dfe44bffad59d996f4753710e0529e5ff648c2305829835c2ab7` — pas de bump sur cette migration.
- litellm-operator reste v0.0.20 — les CRDs `litellmmcpservers`/`litellmteams`/`litellmvirtualkeys` sont déjà installés (13 sept 2026).
- AUCUN secret en clair : tout via ExternalSecret → 1Password. Les `LiteLLMMCPServer` référencent les valeurs via `workload.env[].valueFrom.secretKeyRef` ou `authTokenRef`.
- Les remoteRef 1Password existants (`toolhive-*`, `home-assistant`) restent IDENTIQUES — on ne touche pas à 1Password ; les noms de Secrets k8s restent `toolhive-*` (préfixe devenu historique, à documenter dans le fichier).
- Images pinnées par digest quand le manifest actuel le fait ; versions npx/piPy pinnées avec marker renovate conservé.
- Validation obligatoire avant chaque push : `mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm` puis `flate diff` contre main.
- Ne jamais `git add -A` : n'ajouter que les fichiers créés/modifiés par la tâche.
- Namespace injecté par kustomization (pas de `metadata.namespace` inline).
- `resourceOverrides` n'existe PAS sur `LiteLLMMCPServer` — tolerations/affinity/volumes/resources sont sous `workload.*` (vérifié sur le CRD installé).

## Review Focus

1. **Noms de tools dans les mémoires d'agents** — openclaw stocke des traces d'usage des tools toolhive (`find_tool`/`call_tool`). Après cut-over, les noms deviennent les tools bruts de chaque serveur + `mcp_tool_search`/`mcp_tool_call`. Test : un prompt réel par agent (Task 9/10/11), pas seulement tools/list.
2. **Timeout lightrag (~97 s)** — toolhive avait un contournement proxy 60s. litellm a `request_timeout: 3600` global (litellmproxy.yaml) ; vérifier la 1re call lightrag en Task 11. Si un timeout apparaît malgré tout, tester `params: {timeout: ...}` sur le CR du serveur, sinon issue sur l'opérateur.
3. **Collision de noms de Services** — l'opérateur nomme le Service du workload `<metadata.name>` dans `ai`. Pré-flight `kubectl get svc -n ai` dans Task 4 avant écriture.
4. **ExternalSecrets atomiques** — un remoteRef 1Password erroné fait tomber tout le reconcile ; chaque ES migré doit être vérifié `SecretSynced` (Task 1).
5. **Regression permissions par clé (issue BerriAI #27657)** — les permissions MCP team doivent être exercées par des probes négatives par clé, pas seulement positives (Task 8 Step 6).

---

## Cartographie des migrations (source : `kubernetes/apps/ai/toolhive/`)

| Alias (`metadata.name`) | Groupe | Mode actuel | Mode cible litellm | Spécificité |
|---|---|---|---|---|
| `arr` | mcp-tools | stdio npx mcp-arr-server@1.7.3 | workload + supergateway | 3 secrets sonarr/radarr/prowlarr |
| `ha-mcp` | mcp-tools | streamable-http (`ha-mcp-web`) | workload natif | secret HOMEASSISTANT_TOKEN |
| `seerr-mcp` | mcp-tools | stdio npx @jhomen368/overseerr-mcp@2.3.1 | workload + supergateway | secret SEERR_API_KEY |
| `todoist-mcp` | mcp-tools | stdio npx @doist/todoist-mcp@13.4.0 | workload + supergateway | secret TODOIST_API_KEY ; exclusion `get-overview` (Task 8) |
| `lightrag-mcp` | mcp-tools | stdio uv + patch X-API-Key | workload + mcp-proxy (python) | patch AuthenticatedClient VERBATIM ; affinity k8s-3 ; ~97 s |
| `teslamate` | mcp-tools | MCPServerEntry remote `http://teslamate-mcp.automation:8888/mcp` | url remote | aucun credential |
| `context7` | mcp-devops | stdio npx @upstash/context7-mcp@4.1.1 | workload + supergateway | aucun credential |
| `flux` | mcp-devops | streamable-http `:8000`, SA flux-mcp | workload natif | RBAC flux-mcp déplacé tel quel |
| `github` | mcp-devops | stdio image officielle | workload natif si flags HTTP supportés, sinon supergateway ; dernier recours remote `https://api.githubcopilot.com/mcp` | secret GITHUB_PERSONAL_ACCESS_TOKEN |
| `grafana` | mcp-devops | MCPServerEntry remote sse `http://grafana-mcp.observability:8000/sse` | url remote sse | aucun credential |
| `konflate` | mcp-devops | MCPServerEntry remote `http://konflate.flux-system:8080/mcp` | url remote | aucun credential |
| `kubectl` | mcp-devops | streamable-http, SA kubectl-mcp-readonly | workload natif | RBAC kubectl-mcp déplacé tel quel |
| `radar` | mcp-devops | MCPServerEntry remote `http://radar.radar:9280/mcp` | url remote | aucun credential |
| `talos-mcp` | mcp-devops | streamable-http, talosconfig monté | workload natif | talos.dev ServiceAccount déplacé tel quel |
| `unifi-network` | mcp-devops | streamable-http image native :3000 | workload natif | 2 secrets user/password |

Répartition fichiers : remote = 4 CR (Task 3), workload natif = 5 (Task 4), workload wrappé = 6 (Task 5). Total 15.

---

# PR 1 — Serveurs MCP sous litellm (additif, zéro rupture)

## Task 1: Scaffold `mcp/` + migration des ExternalSecrets

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/mcp/kustomization.yaml`
- Create: `kubernetes/apps/ai/litellm/app/mcp/externalsecrets.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/kustomization.yaml` (ajout `- ./mcp` dans resources)

**Interfaces:**
- Produces: Secrets `toolhive-sonarr`, `toolhive-radarr`, `toolhive-prowlarr`, `toolhive-github`, `toolhive-home-assistant`, `toolhive-lightrag`, `toolhive-seerr`, `toolhive-todoist`, `toolhive-unifi-network-username`, `toolhive-unifi-network-password` alimentés dans `ai` — consommés par Tasks 3-5.

- [ ] **Step 1: Copier les ExternalSecrets verbatim** depuis `kubernetes/apps/ai/toolhive/mcp-servers/*/externalsecret.yaml` vers `mcp/externalsecrets.yaml` (un seul fichier, séparateurs `---` conservés, ZÉRO contenu modifié). Conserver l'anchor YAML `&name toolhive-home-assistant` de ha-mcp s'il existe.
- [ ] **Step 2:** Écrire `mcp/kustomization.yaml` (resources: `./externalsecrets.yaml`) et ajouter `- ./mcp` à `app/kustomization.yaml`.
- [ ] **Step 3: Validation**
  Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/litellm`
  Expected: PASS.
- [ ] **Step 4: Commit**
  ```bash
  git add kubernetes/apps/ai/litellm/app/mcp kubernetes/apps/ai/litellm/app/kustomization.yaml
  git commit -m "feat(ai/litellm): scaffold mcp dir with migrated ExternalSecrets"
  ```

## Task 2: PR 1 ouverte et merge

- [ ] **Step 1:** Push de la branche, PR avec les commits de Task 1 — konflate + flate CI verts → merge. (Le reste des serveurs MCP peut suivre dans PR 1 ou être scindé en PR 2 — au choix selon la taille de review souhaitée.)

## Task 3: Serveurs remote (4 MCPServerEntry → `url`)

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/mcp/remote.yaml` (4 CR)
- Modify: `mcp/kustomization.yaml`

**Interfaces:**
- Produces: 4 `LiteLLMMCPServer` remote (`proxyRef: litellm`) : grafana (sse), konflate, radar, teslamate (http).

- [ ] **Step 1: Écrire les 4 CR** :
  ```yaml
  apiVersion: litellm.home-operations.com/v1alpha1
  kind: LiteLLMMCPServer
  metadata:
    name: grafana
  spec:
    proxyRef: litellm
    url: http://grafana-mcp.observability:8000/sse
    transport: sse
  ```
  konflate : `url: http://konflate.flux-system:8080/mcp` transport http ; radar : `url: http://radar.radar:9280/mcp` transport http ; teslamate : `url: http://teslamate-mcp.automation:8888/mcp` transport http.
- [ ] **Step 2:** flate test hr — PASS.
- [ ] **Step 3: Commit** `git commit -m "feat(ai/litellm): add 4 remote MCP servers via LiteLLMMCPServer url"`

## Task 4: Workloads HTTP natifs (5 serveurs) — ha-mcp, unifi-network, talos-mcp, flux, kubectl

**Files:**
- Create: `mcp/workloads.yaml` (5 CR)
- Create: `mcp/flux-mcp-rbac.yaml` (copie verbatim de `toolhive/mcp-servers/flux-mcp/rbac.yaml`)
- Create: `mcp/kubectl-mcp-rbac.yaml` (copie verbatim de `toolhive/mcp-servers/kubectl-mcp/rbac.yaml`)
- Create: `mcp/talos-serviceaccount.yaml` (copie verbatim de `toolhive/mcp-servers/talos-mcp/talosserviceaccount.yaml`)
- Modify: `mcp/kustomization.yaml`

**Interfaces:**
- Produces: 5 CR mode workload → l'opérateur crée Deployment + Service et dérive l'url (visible dans `status.resolvedURL`). flux/kubectl utilisent `workload.serviceAccountName`, talos monte `talos-mcp-talosconfig`.

Contenu des 5 CR (tous `proxyRef: litellm`, resources requests/limits recopiés du MCPServer source) :

```yaml
# ha-mcp      : image ghcr.io/homeassistant-ai/ha-mcp:8.6.0, port 8086,
#               command [ha-mcp-web], env HOMEASSISTANT_URL=http://home-assistant.automation:8123
#               + HOMEASSISTANT_TOKEN secretKeyRef toolhive-home-assistant (créé par le ES),
#               volume tmp → /tmp
# unifi-network: image ghcr.io/sirkirby/unifi-network-mcp:0.36.2@sha256:ef7ac87ec60c826e3fd4ae28a8674d7b6100325bcad6422e54dd1a6096859585,
#               port 3000, TOUS les env du MCPServer toolhive (UNIFI_*) verbatim,
#               2 secretKeyRef (toolhive-unifi-network-username/password)
# talos-mcp   : image registry.erwanleboucher.dev/eleboucher/talos-mcp:0.0.2, port 8080,
#               env TALOS_MCP_TRANSPORT=http, TALOS_MCP_HTTP_ADDR=":8080",
#               volume talosconfig (secret talos-mcp-talosconfig, defaultMode 0400)
#               monté readOnly /var/run/secrets/talos.dev
# flux        : image ghcr.io/controlplaneio-fluxcd/flux-operator-mcp:v0.61.0@sha256:b253ef07502413bcad89d8fb8f9c01d3cfa070331698323fbd8fe0ae9cfa1cb4,
#               port 8000, args [serve, --transport=http, --port=8000],
#               env RUNTIME_NAMESPACE (fieldRef metadata.namespace), serviceAccountName flux-mcp
# kubectl     : image docker.io/rohitghumare64/kubectl-mcp-server:1.24.0@sha256:17134e36a3e1d3a5e457c12d61e8c7f7c52a7927c6ae4250131dfd95a74a2331,
#               port 8000, args [--transport, streamable-http, --host, 0.0.0.0, --port, "8000", --read-only],
#               env MCP_K8S_PROVIDER=in-cluster, PYTHONUNBUFFERED=1,
#               serviceAccountName kubectl-mcp-readonly
```

- [ ] **Step 1 (pre-flight): collision de noms de Services** — `kubectl get svc -n ai | grep -E '^(ha-mcp|unifi-network|talos-mcp|flux|kubectl)$'` : si une collision, renommer le CR (adapter team lists du Task 7).
- [ ] **Step 2: Écrire les 5 CR + les 3 fichiers RBAC/SA verbatim.**
- [ ] **Step 3:** flate test hr — PASS.
- [ ] **Step 4: Commit** `git commit -m "feat(ai/litellm): migrate 5 native-HTTP MCP workloads off toolhive"`

## Task 5: Workloads stdio wrappés (6 serveurs) — arr, seerr-mcp, todoist-mcp, context7, github, lightrag-mcp

**Files:**
- Create: `mcp/workload-wrapped.yaml` (6 CR)
- Modify: `mcp/kustomization.yaml`

**Interfaces:**
- Consomme: Secrets du Task 1. Produces: 6 CR workload (supergateway pour npm, mcp-proxy pour python).

Motif supergateway (ports uniques arbitraires : arr 8000, seerr 8010, todoist 8020, context7 8030, github 8040, lightrag 8050) :

```yaml
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMMCPServer
metadata:
  name: arr
spec:
  proxyRef: litellm
  workload:
    image: docker.io/node:24-alpine
    port: 8000
    command:
      - npx
      - -y
      - supergateway
      - --stdio
      # renovate: datasource=npm depName=mcp-arr-server
      - "npx -y mcp-arr-server@1.7.3"
      - --outputTransport
      - streamableHttp
      - --streamableHttpPath
      - /mcp
      - --port
      - "8000"
    env:  # HOME=/tmp, NPM_CONFIG_CACHE=/tmp/.npm + env métier + secretKeyRef du MCPServer source (SONARR_URL, SONARR_API_KEY…)
    volumes: [tmp emptyDir] ; volumeMounts /tmp
```

Cas particuliers :
- **github** : tester d'abord les flags HTTP de l'image (`kubectl run -n ai --rm -i --restart=Never --image ghcr.io/github/github-mcp-server ghprobe -- --help`). Si transport streamable-http natif supporté : CR workload natif (port, env GITHUB_PERSONAL_ACCESS_TOKEN secretKeyRef toolhive-github). Sinon : même motif supergateway ; dernier recours : remote `url: https://api.githubcopilot.com/mcp` + `authType: bearer_token` + `authTokenRef` (name toolhive-github, key token). Noter la décision en commentaire YAML.
- **lightrag** : mono-conteneur uv, commande stdio actuelle = script `sh -c` avec patch AuthenticatedClient — le conserver VERBATIM (commentaire de 20 lignes inclus) dans la commande du pod, bridé vers HTTP par mcp-proxy :
  ```yaml
  command: [sh, -c]
  args:
    - >-
      pip install --quiet mcp-proxy && exec mcp-proxy --host 0.0.0.0 --port 8050 -- <SCRIPT LIGHTRAG ACTUEL>
  ```
  (l'expansion `$LIGHTRAG_API_KEY` reste dans le script ; version mcp-proxy pinnée avec marker renovate `datasource=pypi depName=mcp-proxy`). Copier `workload.affinity` (nodeAffinity prefer k8s-3) + `workload.tolerations` (workload=ai) du MCPServer toolhive actuel.
- **todoist** : l'exclusion `get-overview` est traitée au Task 8, PAS ici.

- [ ] **Step 1: probe transport github** (commande ci-dessus) — noter la décision en commentaire YAML du CR github.
- [ ] **Step 2: Écrire le fichier** avec les 6 CR ; reproduire TOUS les commentaires explicatifs toolhive actuels (surtout le bloc lightrag).
- [ ] **Step 3:** flate test hr — PASS.
- [ ] **Step 4: Commit** `git commit -m "feat(ai/litellm): migrate 6 stdio MCP servers to wrapped workloads"`

## Task 6: Merge PR 1 + vérification cluster

- [ ] **Step 1:** `mise exec -- flate test ks --path ./kubernetes/apps` — PASS global ; flate diff vs main (baseline /tmp/baseline, commands de l'AGENTS.md) — diff = ajouts litellm uniquement.
- [ ] **Step 2:** Push + PR 1 + konflate vert → merge. Puis sync Flux (`just kube sync`) et vérifier :
  Run: `kubectl get litellmmcpserver -n ai` — les 15 CR existent, `status.resolvedURL` renseigné pour les 11 workload, pods Running (`kubectl get pods -n ai -l 'kubernetes.io/managed-by' -o wide` + description des pods workload).
- [ ] **Step 3: probe tools/list par workload** (1 pod curl jetable par svc, motif phase 0 : initialize → tools/list) — chaque workload répond avec une liste non vide. NB : les agents restent sur toolhive ; PR 1 est additif.
- [ ] **Step 4: probe des 4 serveurs remote** via le proxy litellm avec master key (pod curl, initialize + tools/list filtré par URL namespacing `http://litellm.../<alias>/mcp`) — 4 réponses attendues.

---

# PR 2 — AuthZ par équipes + tool search

## Task 7: LiteLLMTeam mcp-apps / mcp-devops

**Files:**
- Create: `kubernetes/apps/ai/litellm/app/teams/kustomization.yaml`
- Create: `kubernetes/apps/ai/litellm/app/teams/mcp-apps.yaml`
- Create: `kubernetes/apps/ai/litellm/app/teams/mcp-devops.yaml`
- Modify: `kubernetes/apps/ai/litellm/app/kustomization.yaml` (ajout `- ./teams`)

**Interfaces:**
- Consomme: alias des 15 LiteLLMMCPServer. Produces: `teamID` utilisables par les clés (Task 8) — l'opérateur transmet l'ID généré ; le récupérer après apply via l'API admin `GET /team/list` (pod curl + master key) ou status du CR.

```yaml
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMTeam
metadata:
  name: mcp-apps
spec:
  proxyRef: litellm
  alias: mcp-apps
  mcpServers: [arr, ha-mcp, seerr-mcp, teslamate, todoist-mcp, lightrag-mcp]
---
apiVersion: litellm.home-operations.com/v1alpha1
kind: LiteLLMTeam
metadata:
  name: mcp-devops
spec:
  proxyRef: litellm
  alias: mcp-devops
  mcpServers: [context7, flux, github, grafana, konflate, kubectl, radar, talos-mcp, unifi-network]
```

- [ ] **Step 1: Écrire les 2 CR + kustomization** (alias = listes de la cartographie ci-dessus).
- [ ] **Step 2:** flate PASS ; après sync : les 2 CR Ready ; relever les teamIDs réels (`GET /team/list`) et les consigner dans le commentaire de PR.
- [ ] **Step 3: Commit** `git commit -m "feat(ai/litellm): add mcp-apps/mcp-devops LiteLLMTeams"`

## Task 8: Clés → équipes + tool search + exclusion todoist

**Files:**
- Modify: `kubernetes/apps/ai/litellm/app/virtualkeys/mainclaw.yaml` (+ `teamID: mcp-apps`)
- Modify: `.../virtualkeys/devclaw.yaml`, `.../opencode.yaml` (+ `teamID: mcp-devops`)
- Modify: `kubernetes/apps/ai/litellm/app/litellmproxy.yaml` (litellmSettings `default_key_generate_params`)
- Modify: `mcp/workload-wrapped.yaml` (todoist `params.allowed_tools`)
- Create: `kubernetes/apps/ai/litellm/app/README.md` section MCP (patch one-time clés + exclusion)

**Interfaces:**
- Consomme: teamIDs Task 7. Produces: clés modifiées in place (pas de rotation — opérateur MAJ la clé distante).

Mapping (décisions de design) :
- mainclaw → mcp-apps
- devclaw, opencode, **hermes** → mcp-devops (hermes ajouté par amendement owner du 03 oct)
- foreman, pr-review : À VALIDER avec l'owner — si ces agents n'utilisent pas MCP, sans teamID.
- memini, lightrag, repo-wiki : sans équipe (clés non-MCP).

- [ ] **Step 1: Modifier les virtualkeys** (`teamID` sous `spec` des clés retenues) : mainclaw → mcp-apps ; devclaw, opencode, **hermes** → mcp-devops.
- [ ] **Step 2: tool search par défaut des NOUVELLES clés** — dans `litellmSettings` du proxy :
  ```yaml
  default_key_generate_params:
    object_permission:
      mcp_tool_search_enabled: true
  ```
  (la recherche mcp_tool_search est keyword token-overlap — aucun embedding model à configurer.)
- [ ] **Step 3: exclusion todoist get-overview** — sur le CR todoist, `params.allowed_tools` = liste blanche explicite du tour (todoist a ~10 tools) obtenue par un probe `tools/list` sur le Service du workload todoist ; exclure `get-overview` de la liste. Si la sémantique litellm supporte mieux (listes noires `disallowed_tools` — intervenir si les docs le confirment), préférer la liste noire à un seul élément.
- [ ] **Step 4: patch one-time des clés existantes** — le default ne touche que les NOUVELLES clés ; pour les existantes, `POST /key/update` (pod curl + master key) avec `object_permission: {mcp_tool_search_enabled: true}` pour mainclaw/devclaw/opencode/hermes. Documenter ce patch manuel dans `app/README.md` (section MCP) : pourquoi il est one-time et comment re-appliquer (procédure : drift d'UI).
- [ ] **Step 5:** flate PASS, sync, `kubectl get litellmvirtualkey -n ai` Ready ×N — clés inchangées côté 1Password (PushSecret silencieux).
- [ ] **Step 6: probes authZ (4 probes par clé existante)** :
  1. `tools/list` KEY_MAINCLAW → serveurs apps uniquement (+ 4 tools virtuels).
  2. `tools/list` KEY_DEVCLAW → serveurs devops uniquement.
  3. KEY_MAINCLAW, `mcp_tool_search {query: "kubernetes logs"}` → AUCUN tool devops dans le résultat (anti-#27657).
  4. KEY_MAINCLAW, `tools/call` visant kubectl → 403.
  5. `tools/list` KEY_HERMES → serveurs devops uniquement (incl. key devops-only : AUCUN tool apps).
- [ ] **Step 7: Commit** `git commit -m "feat(ai/litellm): bind virtual keys to MCP teams and enable tool search"`

## Task 9: Gate PR 2 — état de la gateway

- [ ] **Step 1:** re-run les 4 probes authZ de Task 8 Step 6 après reconcile complet.
- [ ] **Step 2:** vérifier l'UI litellm (`litellm.oxygn.dev`) : 15 MCP servers visibles, 2 teams avec les bonnes appartenances.
- [ ] **Step 3:** Note dans la PR : consommation prête pour cut-over, liste des teamIDs, capture UI si utile.

---

# PR 3 — Cut-over des consommateurs

## Task 10: mainclaw (mcp-apps)

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/resources/openclaw.json` (entrée `toolhive`, ligne ~970)

**Interfaces:**
- Consomme: Secret `litellm-key-mainclaw` (key `api-key`) — déjà dans `ai` via PushSecret 1Password ; selon la propagation existante par openclaw, référencer via le mécanisme secret du chart (vérifier comment openclaw.json reçoit ses secrets aujourd'hui : variables `{{…}}`/env, look at the file at execution time).

- [ ] **Step 1: probe pré-cut-over** : pod curl avec KEY_MAINCLAW → initialize + `mcp_tool_search` + 1 call réel réussi sur tool apps.
- [ ] **Step 2:** Éditer openclaw.json : renommer l'entrée `toolhive` → `litellm`, `url: http://litellm-litellm.ai:4000/mcp` (vérifier le nom réel du Service litellm par `kubectl get svc -n ai`), headers auth selon le pattern de résolution secret établi à l'exécution (si interpolation env non supportée : envFrom Secret sur le pod + placeholder).
- [ ] **Step 3:** sync flux, logs openclaw sans erreur MCP ; test fonctionnel réel par l'humain via le canal Discord : une action todoist réussie + une action devops REFUSÉE (le chat doit répondre "pas autorisé").
- [ ] **Step 4: Commit** `git commit -m "feat(ai/mainclaw): switch MCP from toolhive to litellm gateway"`

## Task 11: devclaw (mcp-devops)

**Files:**
- Modify: `kubernetes/apps/ai/devclaw/app/resources/openclaw.json` (entrée `toolhive`, lignes ~336-337) + `kubernetes/apps/ai/devclaw/README.md` (mention toolhive lignes 4-5)

Mêmes steps que Task 10 (probe précut devops incluse).
- [ ] **Step 5: Commit** `git commit -m "feat(ai/devclaw): switch MCP from toolhive gateway-devops to litellm"`

## Task 12: opencode (mcp-devops)

**Files:**
- Modify: `kubernetes/apps/ai/opencode/app/configmap.yaml` (entrée `toolhive`, lignes ~481-483)

Note : opencode parle déjà à litellm (header x-opencode-session session_hook) ; le header MCP peut réutiliser le mécanisme auth identique.
- [ ] **Step 4: Commit** `git commit -m "feat(ai/opencode): switch MCP dev config to litellm gateway"`

## Task 12b: hermes (mcp-devops) — amendement du 03 oct (demande owner)

**Files:**
- Modify: `kubernetes/apps/ai/hermes/app/configmap.yaml` (entrée `mcp_servers.toolhive`, lignes ~87-89)

**Interfaces:**
- Consomme: Secret `litellm-key-hermes` (key `api-key`) + env `LITELLM_API_KEY` déjà injecté dans le pod hermes (les providers litellm du config.yaml l'utilisent déjà) ; teamID mcp-devops (Task 8).

**Décision owner :** hermes passe du groupe internal (mcp-tools) au groupe **devops** — changement de périmètre voulu.

- [ ] **Step 1: probe pré-cut-over** : pod curl avec KEY_HERMES → initialize + `mcp_tool_search` + 1 call réel réussi sur un tool devops (ex. flux).
- [ ] **Step 2:** Éditer configmap.yaml : `mcp_servers.toolhive` → `mcp_servers.litellm`, `url: http://litellm.ai:4000/mcp` (nom svc vérifié réel = `litellm`), auth : les agents hermes authentifient le MCP via le header Authorization Bearer ${LITELLM_API_KEY} — vérifier la syntaxe MCP supportée par hermes (réutiliser le pattern des autres agents openclaw si config identique ; sinon consulter la doc hermes-agent v2026.9.24).
- [ ] **Step 3:** sync flux, rollout hermes, logs sans erreur MCP ; test fonctionnel réel par l'humain.
- [ ] **Step 4: Commit** `git commit -m "feat(ai/hermes): switch MCP to litellm gateway (mcp-devops)"`


## Task 13: Soak 24 h avant teardown

- [ ] **Step 1:** demander à l'humain un test réel pendant 24 h des 3 agents sur litellm (les gateways toolhive restent UP — rollback = ré-éditer openclaw.json/configmap vers l'ancienne URL + git revert).
- [ ] **Step 2:** si anomalie consommateur : rollback Task 10-12 (revert isolé du commit concerné) et pause de PR 4.

---

# PR 4 — Teardown toolhive + docs

## Task 14: Suppression toolhive

**Files:**
- Delete: `kubernetes/apps/ai/toolhive/**` (intégralité : app/, config/, crds/, mcp-servers/, ks.yaml)
- Modify: `kubernetes/apps/ai/kustomization.yaml` (retirer `./toolhive`)
- Modify: `AGENTS.md` (table technologies : `AI | litellm (gateway modèles + MCP)` ; section « MCP Servers » → litellm ; section « AI Agent Role » : groupes = 2 LiteLLMTeam, discovery = mcp_tool_search, endpoint litellm `/mcp`)
- Grep résiduel : `grep -rn toolhive` sur le repo et README.md — nettoyer les références de doc.

⚠️ Les HTTPRoutes `mcp.oxygn.dev` / `mcp-devops.oxygn.dev` n'ont plus de consommateur interne après cut-over (clients = openclaw/opencode in-cluster) : elles sont supprimées avec le dossier. Si un client externe HTTPS se révèle à l'étape 1 (grep logs/dns), les recréer côté litellm (`route:` existe déjà sur le proxy).

- [ ] **Step 1: suppression progressive** — d'abord retirer `mcp-servers/` + `config/` (le toolhive operator purge ses pods), laisser 1 cycle, puis retirer `app/` + `crds/` + `ks.yaml` + l'entrée `./toolhive` du kustomization `ai`. Conserver le git history (suppression = commits propres, pas de force push).
- [ ] **Step 2: vérification cluster** : `kubectl get mcpservers,mcpgroups,virtualmcpserver,embeddingservers -A` → vide ; pods toolhive disparus ; `flux get kustomizations -A` ne liste plus toolhive.
- [ ] **Step 3: update documentation** : AGENTS.md (table technologies, section MCP Servers, section AI Agent Role), grep toolhive sur docs/README.
- [ ] **Step 4:** flate test ks global PASS.
- [ ] **Step 5: Commit** `git commit -m "feat(ai)!: remove toolhive in favor of litellm MCP gateway"`

## Task 15: Validation finale post-merge

- [ ] **Step 1:** `flux get kustomizations -A` — aucun toolhive ; litellm Ready.
- [ ] **Step 2:** probe finale des 3 agents (tools/list + 1 call chacun).
- [ ] **Step 3:** vérifier monitoring : dashboards toolhive supprimés (`config/dashboard`, `grafanadashboard.yaml` toolhive), PodMonitor toolhive parti ; dashboards litellm intacts.
- [ ] **Step 4:** issue de suivi : watch litellm MCP upstream (toolsets, /v1/responses semantic filter comme upgrade possible via qwen3-embedding TEI déjà déployé, permissions tool-level quand le CRD l'exposera) ; noter les images wrappées (supergateway/mcp-proxy) à re-checker en cas de changement upstream des serveurs npx.

---

## Notes de conception (contexte executor)

1. **Pourquoi pas le mode stdio natif de litellm (`transport: stdio` des mcp_servers)** : les subprocess tourneraient dans les pods proxy litellm (2 répliques HA) — couplage d'images (node/uv absent de litellm-database), impact mémoire, restart du proxy à chaque modif de serveur. Le mode workload de l'opérateur isole chaque serveur, suit le pattern home-operations (validé par le repo eleboucher, même opérateur).
2. **stdio ProxyMode toolhive → supergateway (npm) / mcp-proxy (python)** : équivalent 1:1 du `proxyMode: streamable-http` toolhive, mais explicite dans le manifest et piloté par l'opérateur.
3. **EmbeddingServer abandonné** : mcp_tool_search litellm est keyword token-overlap (vérifié docs officielles). Le search sémantique (qwen3-embedding TEI) reste disponible pour l'upgrade `/v1/responses` (`mcp_semantic_tool_filter`) si un jour les agents passent par le Responses API ; pas nécessaire aujourd'hui.
4. **teamID** : vérifier l'ID réel des teams via `GET /team/list` après création (Task 7 Step 2) — l'opérateur transmet à `object_permission.mcp_servers`.
5. **lightrag timeout** : `request_timeout: 3600` global du proxy devrait couvrir les ~97 s ; vérifier première call lightrag (Task 15 / cut-over).
6. **Consommateurs opencode** : litellm a déjà le session_hook x-opencode-session (cache affinity) ; l'auth MCP opencode passe par header Authorization Bearer sur la même clé KEY_OPENCODE — pas de nouveau secret.
7. **k8s-3** : seuls lightrag (affinity prefer + toleration `workload=ai`) parmi les MCP workloads demande le nœud AI — recopier ces deux champs sous `workload.affinity` / `workload.tolerations`.

Les noms de Service opérateur = metadata.name du CR : si un Service toolhive (préfixe `mcp-` pour les pods) porte un nom identique, renommer le CR ET mettre à jour la team list correspondante (Task 4 pre-flight).
