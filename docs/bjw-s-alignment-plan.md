# Alignement sur bjw-s-labs/home-ops — plan de reprise

Revue des **79 commits non-Renovate** (≈520 commits Renovate) de
`git.bjw-s.dev/bjw-s-labs/home-ops` sur la fenêtre **2026-10-20 → 2026-11-26**, filtrés sur ce
qui a un intérêt ici. Chaque item retenu a été vérifié contre ce repo (Talos 1.14.7, Kubernetes
1.37.3, Cilium 1.20.5, app-template 5.3.0).

Périmètre volontairement exclu : ce qui est déjà en place (`nfsrahead` + `/etc/nfs.conf`,
request mémoire CNPG, Kanidm 1.12.1, MCP Grafana, Hermes + SearXNG) et ce qui ne correspond à
aucun usage ici (chaski, Garage/TrueNAS S3, Forgejo-CNPG, k8tz, posteryard, OpenSpec).

---

## 1. Déjà fait

| PR | Contenu | État |
|---|---|---|
| #6112 | Renovate : suivi du tag Postgres CNPG (`cluster.spec.imageName`) | ouverte |
| #6118 | CoreDNS : retrait du plugin `autopath` | ouverte |

## 2. Chantiers retenus

| # | Chantier | Effort | Risque | Statut |
|---|---|---|---|---|
| 3 | Netpols phase 0 : 5 `CiliumClusterwideNetworkPolicy` (no-op) | 1 h | nul | à faire |
| 4 | Netpols phase 1 : namespace `download` de bout en bout | 1 j | moyen | à faire |
| 5 | Netpols phases 2 : `media` → `self-hosted` → `automation` → `ai` → `observability` → `database`/`security` | ~1 ns/app | moyen | à faire |
| 6 | Kaniop : opérateur + migration de l'IdP | spec + fenêtre | élevé | à instruire |
| 7 | Pod Security : `audit`/`warn` global, puis `enforce` par namespace | 1 j | moyen | à faire |
| 8 | gVisor (`RuntimeClass`) sur les runners ARC | 1 j | moyen | à faire |
| 9 | Agent Gateway en remplacement de LiteLLM | spike séparé | élevé | à instruire |

Ordre recommandé : 3 → 4 → 5, puis 6 (indépendant), puis 7 (bénéficie des netpols en place),
puis 8, puis 9. Le 6 est le seul à exiger une fenêtre et une coupure de service.

---

## 3. Segmentation réseau

### 3.1 Modèle

Ce n'est pas un default-deny par namespace : c'est un gating **piloté par labels,
cluster-wide, additif**, donc migrable app par app sans flag day. Un pod qui ne porte aucun des
trois labels conserve exactement le comportement actuel.

Cinq policies cluster-wide (`kubernetes/apps/kube-system/cilium/netpols/`) :

| Policy | Sélecteur de pods | Effet |
|---|---|---|
| `allow-default-egress` | pods sans **aucun** des 3 labels | tout autorisé (statu quo) |
| `block-all-egress` | `<prefix>/block-all: "true"` | egress `- {}` : tout refusé |
| `allow-dns-egress` | `{}` (tous les pods) | kube-dns :53 UDP/TCP + `rules.dns.matchPattern: "*"` |
| `allow-internet-egress` | `<prefix>/internet: "true"` | `toEntities: [world]` |
| `allow-kube-api-egress` | `<prefix>/kube-api: "true"` | `toEntities: [kube-apiserver]` |

Elles s'additionnent : un pod `block-all` garde DNS, et l'internet seulement s'il porte aussi
`internet`. Préfixe de labels : bjw-s utilise `egress.policy.home.arpa/`, ici
**`egress.policy.oxygn.dev/`**.

### 3.2 Côté application

Inline dans le HelmRelease, via app-template (`type: cilium`) — disponible en 5.3.0 :

```yaml
      networkpolicies:
        radarr:
          type: cilium
          egress:
            - toEndpoints:
                - matchLabels:
                    k8s:io.kubernetes.pod.namespace: download
                    app.kubernetes.io/name: prowlarr
              toPorts:
                - ports: [{ port: "80", protocol: TCP }]
          ingress:
            - fromEndpoints:
                - matchLabels:
                    k8s:io.kubernetes.pod.namespace: network
                    # label des pods Envoy : à confirmer en cluster (cf. 3.5)
                    gateway.networking.k8s.io/gateway-name: envoy-internal
              toPorts:
                - ports: [{ port: "80", protocol: TCP }]
```

Le label de gating se pose sur le pod (`controllers.<nom>.pod.labels`) :

```yaml
      controllers:
        qbittorrent:
          pod:
            labels:
              egress.policy.oxygn.dev/block-all: "true"
              egress.policy.oxygn.dev/internet: "true"
```

Deux conséquences à intégrer :

- dès qu'un pod est sélectionné par **une** policy, **tout ingress non listé est refusé** — c'est
  l'objectif, mais c'est aussi ce qui casse silencieusement les scrapes et les sondes ;
- l'ordre compte : écrire les règles **puis** poser `block-all`, jamais l'inverse.

### 3.3 Phases

**Phase 0** — créer les 5 policies. Aucun pod ne portant les labels, c'est un no-op
vérifiable : hubble ne montre aucun drop, aucune app ne bouge.

**Phase 1 — `download`** (prowlarr, qbittorrent, sabnzbd, qui, radarr, sonarr, decluttarr).
Namespace le plus petit, dépendances connues, et c'est là que se trouvent les flux les plus
latéraux (les *arr s'appellent entre eux). Livrable : policies par app + `block-all` +
`internet` sur qbittorrent et prowlarr, puis 24 h d'observation hubble.

**Phase 2** — `media` (audiobookshelf, maintainerr, plex, seerr, tautulli), puis
`self-hosted`, `automation`, `ai`, `observability`, et en dernier `database` + `security`
(CNPG, Kanidm : les flux opérateur ↔ instance et kopiur ↔ PVC demandent le plus d'attention).

### 3.4 Checklist avant de poser `block-all` sur un namespace

- [ ] ingress depuis la gateway (`envoy-internal` et/ou `envoy-external`) sur le bon port
- [ ] ingress depuis `observability` (scrape Prometheus, `ServiceMonitor`, exporters sidecar)
- [ ] egress DNS (couvert par `allow-dns-egress`, rien à faire)
- [ ] egress vers les dépendances réelles (Postgres, cache, API internes) avec ports explicites
- [ ] egress `world` si l'app sort (indexeurs, notifications, mises à jour)
- [ ] egress `kube-api` si l'app lit l'API (opérateurs, controllers, ARC)
- [ ] sondes kubelet : vérifier qu'aucune probe ne tombe (trafic `host`)
- [ ] 24 h de hubble sans drop inattendu avant de considérer la phase close

Rollback : retirer le label `block-all` du pod. Immédiat, sans redéploiement d'image.

### 3.5 Inconnues à lever en cluster (bloquantes pour la phase 1)

1. **Label des pods Envoy** : `gateway.networking.k8s.io/gateway-name` (utilisé par bjw-s) ou
   `gateway.envoyproxy.io/owning-gateway-name` selon la version d'Envoy Gateway. À vérifier avec
   `kubectl get pods -n network --show-labels` avant d'écrire douze fichiers faux.
2. **Sondes kubelet** : confirmer qu'elles ne sont pas filtrées par une policy d'ingress sur le
   premier namespace migré (une probe cassée = restart loop, visible immédiatement).
3. **Ports réels** : l'inventaire indique `:80` pour toutes les apps de `download` et `50469`
   pour le port torrent de qbittorrent ; à confirmer service par service.

---

## 4. Kaniop

Opérateur `kaniop.rs` (Rust, AGPL-3.0, chart `oci://ghcr.io/pando85/helm-charts/kaniop`
v0.25.0), actif. CRDs : `Kanidm`, `KanidmPersonAccount`, `KanidmGroup`, `KanidmServiceAccount`,
`KanidmOAuth2Client`, `KanidmRadiusServer`, `KanidmBackup{Repository,Schedule,Backup}`,
`KanidmRestore`.

### 4.1 Ce que ça remplacerait

| Aujourd'hui | Avec kaniop |
|---|---|
| HelmRelease app-template `security/kanidm` (StatefulSet + config) | CR `Kanidm` |
| sidecar `kanidm-provision` + ConfigMaps `kanidm_config: "1"` | CR `KanidmOAuth2Client` par app |
| Secret `kanidm-${APP}-oidc` (clés `client-id` / `client-secret`) | Secret `<nom>-kanidm-oauth2-credentials` (clés `CLIENT_ID` / `CLIENT_SECRET`, aliasables) |
| renouvellement TLS via reloader | hash du secret injecté dans le pod template ⇒ restart auto |
| — | `secretRotation`, `claimMap`/`scopeMap`, personnes/groupes/comptes de service déclaratifs |

`kanidmName` permet de conserver l'identifiant Kanidm (= `${APP}`) et donc les issuers
`https://idm.oxygn.dev/oauth2/openid/<app>` : aucune app n'a à changer de `clientID`.
Le `SecurityPolicy` Envoy devra pointer sur le nouveau nom de Secret et la clé `CLIENT_SECRET`
(ou `secretKeyAliases` pour garder `client-secret`).

### 4.2 Contraintes dures

- `Kanidm.spec.storage` n'accepte que `emptyDir` / `ephemeral` / `volumeClaimTemplate` — **pas
  d'`existingClaim`**. Impossible d'adopter la PVC actuelle.
- Backup/restore kaniop est **expérimental** (pas de contrat de fin d'écriture côté Kanidm, le
  transport distant repose sur des heuristiques). Le backup local (`KanidmBackupSchedule`,
  `localVersions: 7`, fichiers sous `/data/backups` sur la PVC) est utilisable ; kopiur reste le
  vrai DR.
- `schedule` / `kanidmRef` / `repositoryRef` / `retention` sont immuables après le premier
  backup ; de même que bucket/prefix/endpoint d'un `KanidmBackupRepository` déjà utilisé.

### 4.3 Décision ouverte n° 1

**Kaniop peut-il piloter un Kanidm qu'il ne gère pas ?** Si les CRs `KanidmOAuth2Client` exigent
un `Kanidm` managé (le cas le plus probable : l'opérateur a besoin d'un compte de service qu'il
crée lui-même), la migration est nécessairement un basculement complet. À trancher en lisant
`docs/` de kaniop avant d'écrire quoi que ce soit.

### 4.4 Option A — bascule complète en fenêtre

1. `kanidm domain backup` sur l'instance actuelle (`kubectl exec`), récupérer l'artefact.
2. Déployer kaniop + un CR `Kanidm` neuf (`domain: idm.oxygn.dev`, image 1.12.1, PVC neuve).
3. `KanidmRestore` avec `restoreImage` **identique** à `Kanidm.spec.image` (immuable).
4. Vérifier : login admin, clients OAuth2, certificat, `well-known` ; puis basculer le
   `BackendTLSPolicy` / les `SecurityPolicy`.
5. Conserver l'ancienne PVC (et l'artefact de backup) au moins 7 jours.

Durée : 1 à 2 h de coupure IdP (les apps OIDC tombent pendant la bascule).

### 4.5 Option B — coexistence puis bascule (préférée si 4.3 le permet)

Kaniop en observation sur un Kanidm existant, un seul client pilote migré, puis bascule
générale. Zéro coupure, mais dépend entièrement de la réponse à 4.3.

### 4.6 Ce qu'il faut décider

- [ ] Option A ou B (dépend de 4.3)
- [ ] garder `client-secret` via `secretKeyAliases`, ou adapter les `SecurityPolicy` à `CLIENT_SECRET`
- [ ] conserver kopiur en plus du backup natif (recommandé : oui)
- [ ] périmètre de la première PR : opérateur seul, ou opérateur + CR `Kanidm` + restore

---

## 5. Pod Security (item 7)

Aucun label PSS dans le repo sauf `miroir-system: privileged`. bjw-s injecte
`pod-security.kubernetes.io/enforce: baseline` sur tout nouveau namespace via une
`MutatingAdmissionPolicy` (+ binding), avec opt-down `audit` et provenance (`*-injected: "true"`)
pour retirer proprement un `enforce` injecté.

Ici : démarrer en **`audit` + `warn`** par défaut (pas `enforce`), mesurer sur les workloads
`kube-system`, `ai`, `observability`, puis passer `enforce` namespace par namespace. Seuls ARC et
Cilium ont des privilèges ; `download` passerait `baseline` sans changement.

## 6. gVisor sur les runners ARC (item 8)

Les runners ARC exécutent du code de PR non fiable avec un token GitHub dans le même pod.
`RuntimeClass` gVisor sur les pods runners (extension Talos + node dédié) réduit la surface.
À faire après les netpols, indépendant du reste.

## 7. Agent Gateway (item 9)

bjw-s a supprimé LiteLLM (operator, CRs de modèles, teams, virtual keys, MCP servers, cluster
CNPG) au profit d'`agentgateway-standalone` v1.7.0, avec MCP routé par chemin (`/mcp/<nom>`) et
`backendAuth` par cible. Ce qui serait perdu ici : virtual keys/teams, budgets et tracking de
spend, et les 4 virtual tools (`mcp_tool_search`, …) sur lesquels repose le tool-discovery des
agents. **Spike séparé, pas dans ce plan** ; deux idées sont réutilisables sans migrer : des
endpoints MCP adressables séparément, et un secret de session hors ConfigMap.

---

## 8. Écarté, et pourquoi

| Sujet | Raison |
|---|---|
| Valkey à la place de Dragonfly | perd le HA 2 réplicas utilisé par ghostfolio + litellm ; à reconsidérer seulement si l'operator pose problème |
| PVC `miroir-local-slow` pour les caches CI | utile uniquement si les jobs re-tirent trop d'images ; coût ~200 Gi local à surveiller |
| OpenSpec | le couple AGENTS.md + skills couvre déjà le process |
| Chaski, Garage → TrueNAS S3, Forgejo-CNPG | aucun usage correspondant ici |
| kGuardian | optionnel, après les netpols, pour proposer des policies à partir du trafic réel ; projet jeune, broker 2 Gi |

## 9. Références

- Modèle réseau : `kubernetes/apps/kube-system/cilium/netpols/*.yaml` (bjw-s), PR #2203
- Pod Security : commit `56e22d84` + correctifs de provenance (bjw-s)
- Kaniop : <https://pando85.github.io/docs/kaniop/latest/>, chart 0.25.0
- Agent Gateway : PR #2058 (bjw-s)
