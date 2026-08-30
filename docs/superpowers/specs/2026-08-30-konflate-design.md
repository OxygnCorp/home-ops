# konflate — Design

**Date**: 2026-08-30
**Status**: Approved
**Branch**: `add-konflate`

## Contexte

Le repo `OxygnCorp/home-ops` est un monorepo GitOps (Flux) où un simple bump de version
HelmRelease peut ajouter/supprimer/muter des dizaines de ressources renderues. Le diff git
ne montre pas ce blast radius. [konflate](https://github.com/home-operations/konflate)
(home-operations, même org que flate déjà utilisé en CI) render le cluster Flux au
merge-base et au head de chaque PR, diffuse le résultat, et expose une UI web de review
avec blast radius, changements d'images, échecs de render et flags de danger
(champs immutables, perte de données, privilèges, RBAC).

## Décisions

| Sujet | Décision |
|---|---|
| Approche | HelmRelease Flux du chart OCI officiel `oci://ghcr.io/home-operations/charts/konflate` |
| Namespace | `flux-system` (outil adjacent à Flux), path `kubernetes/apps/flux-system/konflate/` |
| Auth GitHub | GitHub App **Mushu-bot** existante (AppID 1140279) — tokens d'installation courts, pas de PAT |
| Write-back | Status checks **et** commentaires de PR (opt-in) |
| Exposition | Interne uniquement : HTTPRoute → Gateway `envoy-internal` (network), hostname `konflate.oxygn.dev` |
| MCP | `KONFLATE_MCP=true` — endpoint read-only `/mcp` pour l'agent Puchu (review de PRs par blast radius renderu) |
| Secrets | ExternalSecret depuis l'item 1Password `github` existant → clé `KONFLATE_APP_PRIVATE_KEY` ; `secret.existingSecret: konflate` |
| Client ID | Literal dans les values (identifiant public, non sensible), récupéré depuis `GITHUB_APP_CLIENT_ID` (1Password) |
| Refresh | `10m` (pas de webhook possible : UI interne injoignable depuis GitHub) |
| Persistence | PVC `5Gi` (storageClass défaut `miroir-slow`) : cache flate, miroir git, shelf des PRs mergés |
| Monitoring | ServiceMonitor activé (Prometheus découvre tous les ServiceMonitors) |
| Vérif images | `verifyImages: true` — détecte les images typo'd/non poussées avant `ImagePullBackOff` |
| Resources | requests `200m`/`512Mi`, limit `2Gi` (renders repo-wide gourmands ; GOMEMLIMIT dérivé du limit) |
| Forks | Rendu désactivé (défaut) — forks listés mais cachés, jamais renderus |
| Filtre PRs | Défaut (`true`) — toutes les PRs ouvertes, mono-cluster |

## Structure des fichiers

```
kubernetes/apps/flux-system/konflate/
├── ks.yaml                  # Flux Kustomization → ./app, targetNamespace flux-system
└── app/
    ├── kustomization.yaml   # namespace: flux-system
    ├── ocirepository.yaml   # oci://ghcr.io/home-operations/charts/konflate
    ├── helmrelease.yaml     # values détaillées ci-dessous
    └── externalsecret.yaml  # PEM Mushu-bot depuis 1Password item "github"
```

Plus : ajout de `- ./konflate/ks.yaml` dans `kubernetes/apps/flux-system/kustomization.yaml`.

## Values HelmRelease (essentielles)

```yaml
config:
  repo: github://OxygnCorp/home-ops
  refreshInterval: 10m
  appClientId: <Mushu-bot client ID>      # identifiant public
  statusChecks: true
  prComments: true
  publicUrl: https://konflate.oxygn.dev
  mcp: true
  verifyImages: true
secret:
  existingSecret: konflate                 # clé KONFLATE_APP_PRIVATE_KEY
httpRoute:
  enabled: true
  parentRefs: [{name: envoy-internal, namespace: network}]
  hostnames: [konflate.oxygn.dev]
persistence:
  enabled: true
  size: 5Gi
monitoring:
  serviceMonitor:
    enabled: true
resources:
  requests: {cpu: 200m, memory: 512Mi}
  limits: {memory: 2Gi}
deploymentAnnotations:
  reloader.stakater.com/auto: "true"
```

## ExternalSecret

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: konflate
spec:
  refreshInterval: 1h
  secretStoreRef: {kind: ClusterSecretStore, name: onepassword}
  target:
    name: konflate
  data:
    - secretKey: KONFLATE_APP_PRIVATE_KEY
      remoteRef: {key: github, property: GITHUB_APP_PRIVATE_KEY}
```

## Contraintes et points d'attention

- **Single instance** : `replicaCount: 1`, strategy `Recreate` imposée par le chart
  (état en mémoire + PVC RWO) — ne pas modifier.
- **Mushu-bot permissions** (vérifiées OK par l'utilisateur) : Pull requests R/W,
  Commit statuses R/W (ou Checks R/W) — konflate bascule automatiquement en commit
  status si Checks manque.
- **Pas de webhook/push token** : `POST /hooks` et `POST /api/prs/{n}/refresh`
  restent désactivés (501) — le refresh périodique 10m fait office de backstop.
- `KONFLATE_APP_CLIENT_ID` n'est pas lisible via `secret.existingSecret` (le chart ne
  liste que TOKEN/WEBHOOK/PUSH/WRITE/PRIVATE_KEY) → literal dans `config.appClientId`.
- Installation ID non requis : konflate auto-détecte l'installation de l'App sur le repo.
- Gestion d'erreurs : le chart embarque probes `/healthz` `/readyz`, remédiation
  Helm (`retries: 3` en upgrade), et le write-back est best-effort (retry + re-post au
  prochain render).

## Révision 2026-08-30 (n°2) — Alignement upstream (onedr0p)

Après comparaison avec l'implémentation de référence de onedr0p (konflate déployé dans
son home-ops), pivot validé par l'utilisateur :

| Élément | Décision initiale | Révision |
|---|---|---|
| Exposition | interne (`envoy-internal`) | **publique** (`envoy-external`, via tunnel Cloudflare `*.oxygn.dev`) — repo public, rien de privé exposé |
| Chart | `0.3.0` | **`0.6.2`** (la découverte initiale de tag était faussée par le tri lexical de l'API registry) |
| Webhook | aucun (UI interne) | **`KONFLATE_WEBHOOK_SECRET`** (item 1Password dédié `konflate`) → renders instantanés sur push GitHub |
| `refreshInterval` | `10m` | défaut `30m` (le webhook gère l'immédiateté) |
| Workflow CI `flate.yaml` | conservé | **supprimé** — konflate assume commentaires de diff + status checks (write-back déjà activé) ; `image-pull.yaml` conservé (CLI flate indépendant) |
| Gatus | — | annotation `gatus.home-operations.com/endpoint` sur la HTTPRoute (comme onedr0p et seerr) |

Prérequis manuels :
1. Item 1Password `konflate` avec champ `KONFLATE_WEBHOOK_SECRET`.
2. Après merge : webhook GitHub `https://konflate.oxygn.dev/hooks` (content-type json,
   même secret) — créable via `gh api`.

Conservé malgré la divergence upstream : persistence 5Gi, resources relevées,
`reloader.stakater.com/auto` — strictement meilleurs que le setup de référence.

## Validation

- `mise exec -- flate test ks --path ./kubernetes/apps/flux-system`
- `mise exec -- flate test hr --path ./kubernetes/apps/flux-system/konflate`
- `mise exec -- flate diff ks|hr` contre `origin/main` (worktree baseline)
- Post-merge : `flux reconcile kustomization flux-system`, puis vérifier
  `kubectl -n flux-system get pods,pvc,externalsecret` et l'UI sur
  https://konflate.oxygn.dev (interne).
