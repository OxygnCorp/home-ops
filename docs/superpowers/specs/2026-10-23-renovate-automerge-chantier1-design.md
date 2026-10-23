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

b. **Nouvelle règle large** — l'exclusion des composants core est faite
   **dans la règle elle-même** via une regex negative-lookahead sur
   `matchPackageNames` (et non une règle additive séparée), car `addLabels`
   est `mergeable` : un label posé sur la règle large hériterait sinon sur
   les règles d'exclusion suivantes (leak). Verbatim :

```json5
{
  description: "Auto-merge minor/patch/digest updates (3-day release age, non-core packages)",
  matchDatasources: ["docker"],
  matchUpdateTypes: ["minor", "patch", "digest"],
  matchPackageNames: ["/^(?!.*(?:coredns|envoyproxy/gateway|envoy-gateway|gateway-api|cilium|authentik|1password|external-secrets|cert-manager|kanidm|cloudnative-pg|openebs|miroir|kopiur|tuppr|rook-ceph|litellm|toolhive|memini|mcp-grafana|unifi-network-mcp|konflate|gha-runner-scale-set|flux-operator|flux-instance|kube-apiserver|kube-controller-manager|kube-proxy|kube-scheduler|kubelet|envoy))/"],
  automerge: true,
  automergeType: "pr",
  minimumReleaseAge: "3 days",
  ignoreTests: false,
  addLabels: ["automerge"],
}
```

- `minimumReleaseAge: "3 days"` : filet contre les releases défectueuses des
  3 premiers jours (incidents avec binaries "broken" publiés corrigés ensuite).
- `addLabels: ["automerge"]` : sert de filtre au workflow AI review (§4) et
  permet à l'utilisateur de reconnaître d'un coup d'œil une PR à ne pas merger.

c. **Règle d'exclusion core — filet de sécurité** (placée après la règle
   large ; sans `addLabels`, donc héritée par les packages core uniquement
   via leur match : l'exclusion n'ajoute rien : les composants sont déjà
   non-matchés par la règle large ; cette règle pose `automerge: false`
   comme dernier mot, indépendamment du lookahead) :

```json5
{
  description: "Exclude core/sensitive components from automerge",
  matchDatasources: ["docker"],
  matchUpdateTypes: ["minor", "patch", "digest"],
  matchPackageNames: [
    // Réseau / DNS / gateway
    "/coredns/",
    "/envoyproxy/envoy/",
    "/envoyproxy/gateway/",
    "/envoy-gateway/",
    "/gateway-api/",
    "/cilium/",
    // Secrets / identité
    "/authentik/",
    "/1password/",
    "/external-secrets/",
    "/cert-manager/",
    "/kanidm/",
    // Stockage / données
    "/cloudnative-pg/",
    "/openebs/",
    "/miroir/",
    "/kopiur/",
    "/tuppr/",
    "/rook-ceph/",
    // Chaîne d'IA / délégation (litellm fait tourner l'AI review)
    "/litellm/",
    "/toolhive/",
    "/memini/",
    "/mcp-grafana/",
    "/unifi-network-mcp/",
    "/konflate/",
    // CI / GitOps core
    "/gha-runner-scale-set/",
    "/flux-operator/",
    "/flux-instance/",
    "/kube-apiserver/|/kube-controller-manager/|/kube-proxy/|/kube-scheduler/|/kubelet/",
    "/factory\\.talos\\.dev/",
    "/siderolabs/installer/",
  ],
  automerge: false,
}
```

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

`.github/workflows/ai-pr-review.yaml` — condition du job `review-pr`,
ainsi les PR labellisées `automerge` (350 tokens de prompt + coût GPU
inutiles) ne déclenchent plus de review :

```yaml
if: ${{ (github.event_name == 'pull_request' && !github.event.pull_request.draft
  && !contains(github.event.pull_request.labels.*.name, 'automerge'))
  || github.event_name == 'workflow_dispatch' }}
```

- `workflow_dispatch` passe à travers (re-review manuelle possible sur demande).
- Le label d'event `ai-review` (re-review forcé) reste possible : la review
  peut être relancée à la main via `workflow_dispatch`. On accepte que les PR
  entièrement automergées échappent à la review AI (c'est le but : ces
  packages sont jugés moins critiques).

### 5. Notifications GitHub (côté utilisateur, aucun code)

- GitHub → Settings → Notifications → Custom routing: mute `OxygnCorp/home-ops`
  sur les PRs ouvertes par `mushu-bot[bot]`, ou utiliser "Participating &
  @mentions only" sur le repo + garder les mentions/dashboards.
- Les PRs exclusions core continuent de notifier normalement (pas de label
  `automerge` sur elles, donc on les voit dans le flux).

## Non-goals

- **Chantier 2** (merge automatique quand le verdict AI review est "approve")
  : hors du périmètre de cette spec, traité dans une spec séparée.
- Mettre en place une branch protection sur `main` : analyse hors scope. En
  l'absence de protection, les garde-fous reposent sur les exclusions
  explicites ci-dessus et sur le revert one-click.
- Ne pas couvrir `github-release` (`mise` updates) dans l'automerge : le
  datasource github-releases peut déclencher des builds/binary swaps pas
  toujours compatibles et reste manuel.
- Ne pas changer le comportement des groupes Renovate (multi-packages) :
  ils créent une PR groupée — l'automerge s'y applique selon les règles
  actuelles (les composants core groupés sont exclus).

## Test / validation

1. **Config Renovate** : `renovate-config-validator` sur les fichiers
   `.renovate*.json5` (renovate offre un mode validateur : l'operator log
   "Error obtaining docker token" n'est pas bloquant). Le changement est
   declaratif, aucune ligne de code runtime.
2. **YAML k8s** : `flate test ks --path ./kubernetes/apps/renovate` (HR et
   RenovateJob validés).
3. **Workflow GitHub** : `yamllint`/schema json.schemastore.github-workflow
   passe.
4. **Observation post-merge (fenêtre de 5-7 jours)** : comparer
   `mergedBy == oxygn-admin` vs `mushu-bot` sur les nouvelles PRs. Cible :
   ratio auto/humain ≥ 2:1 (vs 1:3.5 aujourd'hui), zéro incident sur composant
   core.

## Rollback

- Revert de la PR unique portant tous ces changements.
- Les PRs Renovate déjà créées ne sont pas affectées ; les nouvelles PRs se
  re-créent conformément à la config précédente au run suivant.
- Une automerge défectueuse qui serait détectée en prod : revert one-click de
  la PR concernée, puis Flux re-live.

## Risques

| Risque | Mitigation |
|---|---|
| Breakage anticipé d'un composant "trusted" non-exclu | `minimumReleaseAge: 3 days` + revert one-click |
| Hallucination de liste d'exclusion (oubli d'un composant) | La liste est conservée explicite et documentée ; konflate commente les PRs de tout de façon ; audit simple via PR reviews visuelles du changelog cette PR |
| Cadence 30 min augmente les runs ratés / rate limits | DiscoveryFilters reste sur `OxygnCorp/*`; log l'opérateur va atteindre les rate-limits éventuels (le problème existing "Error obtaining docker token" fait mention d'un souci qu'il faut investiguer à part) |
| AI review skip sur PR automergée = perte de la seconde opinion | Volontaire ; le filet principal devient konflate (commentaire systématique) + release-age |
