# Chantier 1 — Élargissement de l'automerge Renovate

**Date :** 2026-10-23
**Statut :** Draft pour review
**Objectif :** réduire le nombre de PR Renovate mergées manuellement (~75 sur les
150 dernières PR mergées), sans perdre les garde-fous sur les composants core.

## Contexte et constats

- Sur les ~150 dernières PR mergées : 33 automergées par Renovate, 117 à la main.
  Parmi les 117, ~75 sont des PR Renovate `minor/patch/digest` (docker/helm) qui
  seraient couvertes par une règle d'automerge élargie.
- **Découverte clé :** ~25 de ces PR manuelles sont déjà couvertes par les règles
  automerge *actuelles* de `.renovate/autoMerge.json5` (ex. patches
  `home-operations/*`, images `renovatebot`). Le facteur limitant est la
  **cadence horaire** de Renovate (`schedule: 0 * * * *` dans le `RenovateJob`) :
  l'utilisateur merge la PR ~2 min après sa création, avant le run suivant où
  Renovate exécuterait l'automerge (les règles conteneurs utilisent
  `ignoreTests: false`, donc l'automerge attend des checks verts).
- Le preset global `:automergeBranch` est actif dans `.renovaterc.json5` :
  les automerges sans règle explicite fusionnent **sans PR** (revert difficile,
  pas de commentaire konflate, pas de trace PR).
- Le workflow AI PR Review se déclenche sur toutes les PR, y compris celles
  destinées à être automergées : coût inutile.
- Aucune branch protection sur `main` : rien ne bloque un merge automatique
  (prérequis de l'automerge, mais aussi raison supplémentaire pour des
  exclusions explicites).

## Changements

### 1. `.renovaterc.json5` — retirer `:automergeBranch`

Retirer le preset `:automergeBranch` de la liste `extends`. Tous les automerges
passent par `automergeType: "pr"` (explicité dans chaque règle d'automerge).
Raison : une PR mergée se revert en un clic (`Revert` sur la PR) ; un merge de
branche ne laisse qu'un commit à revert à la main dans l'historique.

### 2. `.renovate/autoMerge.json5` — règle large + exclusions

Ordre des rules (ordre significatif : les plus récentes en bas gagnent) :

a. **Conserver** les règles actuelles (home-operations digests/patches,
   kube-prometheus-stack, renovate, GH actions) telles quelles — elles
   fonctionnent.

b. **Nouvelle règle large** — l'exclusion des composants core ne peut pas
   se faire par regex negative-lookahead sur `matchPackageNames` : le
   config-validator de Renovate rejette les lookarounds dans ces patterns
   ("Failed to parse regex pattern"). Elle ne peut pas non plus utiliser le
   label `automerge` : `addLabels` est `mergeable` et hériterait sur les
   règles suivantes (leak). Le marker retenu est `additionalBranchPrefix: "am-"`
   (non-mergeable : la règle d'exclusion le réinitialise à ""), et le
   workflow AI PR Review skippe les branches `renovate/am-*` via
   `startsWith(github.event.pull_request.head_ref, 'renovate/am-')`.
   Règle large (verbatim final) :

```json5
{
  description: "Auto-merge minor/patch/digest updates (1-hour release age, non-core packages)",
  matchDatasources: ["docker"],
  matchUpdateTypes: ["minor", "patch", "digest"],
  automerge: true,
  automergeType: "pr",
  minimumReleaseAge: "1 hour",
  ignoreTests: false,
  additionalBranchPrefix: "am-",
}
```

c. **Règle d'exclusion core** : réinitialise `additionalBranchPrefix: ""`
   (le marker ne fuit pas sur les core) puis pose `automerge: false`
   indépendamment (dernier mot, docker+minor/patch/digest uniquement) :
   coredns, envoyproxy/envoy + gateway(-helm), envoy-gateway, gateway-api,
   cilium, authentik, 1password, external-secrets, cert-manager, kanidm,
   cloudnative-pg, openebs, miroir, kopiur, tuppr, rook-ceph, litellm,
   toolhive, memini, mcp-grafana, unifi-network-mcp, konflate,
   gha-runner-scale-set, flux-operator, flux-instance, kube-apiserver,
   kube-controller-manager, kube-proxy, kube-scheduler, kubelet,
   factory.talos.dev, siderolabs/installer (regex-strings dans
   `matchPackageNames`) :

c. **Règle d'exclusion core — filet de sécurité** (placée après la règle
   large ; sans `addLabels`, donc héritée par les packages core uniquement
   via leur match : l'exclusion n'ajoute rien : les composants sont déjà
   non-matchés par la règle large ; cette règle pose `automerge: false`
   comme dernier mot — Voir (b) pour le verbatim de la règle ci-dessus) :



> Note de cohérence : cette exclusion neutralise par-dessus **toutes** les
> règles antérieures pour ces packages. C'est voulu : les composants core
> restent à double validation (Renovate ouvre la PR, konflate commente,
> humain merge). Si un jour un composant core est jugé "trusted", on ajoute
> une règle d'exception *encore en dessous*, jamais au-dessus.

d. **No-major (défense en profondeur)** :

```json5
{
  description: "Never auto-merge major updates",
  matchUpdateTypes: ["major"],
  automerge: false,
}
```

### 3. Cadence Renovate — passer d'horaire à demi-horaire

`kubernetes/apps/renovate/renovate-operator/jobs/github.yaml` :
`schedule: 0 * * * *` → `schedule: */30 * * * *`.

Effet : une PR automergée suite à une création attend au plus ~30 min au lieu
d'une heure. De quoi laisser aux règles automatiques le temps de fusionner
avant que l'utilisateur réagisse à une notification résiduelle.

### 4. Skip du workflow AI PR Review sur les PR automergées

`.github/workflows/ai-pr-review.yaml` — condition du job `review-pr` :
skip des branches `renovate/am-*` posées par la règle large de `.renovate/autoMerge.json5` :

```yaml
if: ${{ (github.event_name == 'pull_request' && !github.event.pull_request.draft && !startsWith(github.event.pull_request.head_ref, 'renovate/am-')) || github.event_name == 'workflow_dispatch' }}
```

- `workflow_dispatch` passe à travers (re-review manuelle possible sur demande).
- Le label d'event `ai-review` (re-review forcé) reste possible hors des
  branches `am-` ; les PRs automergées échappent à la review AI (c'est le but :
  ces packages sont jugés moins critiques). Une review de secours reste
  déclenchable à la main via `workflow_dispatch`.


