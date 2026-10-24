# Chantier 2 — Auto-merge des PR Renovate core sur verdict AI approve

**Date :** 2026-10-24
**Statut :** Approuvé à l'oral (option 2 — merge direct par le workflow).
**Objectif :** une PR Renovate patch/minor touchant les composants core
(précédemment exclus de tout automerge) est mergée automatiquement quand
l'AI PR Review l'approuve intégralement. Restent 100% manuels : tout bump
`major`, tout upgrade Talos / Kubernetes.

## Mécanisme

`.github/workflows/ai-pr-review.yaml` :

1. `publish-mode: review_verdict` : le verdict final devient une review
   **native** GitHub (`APPROVE` / `REQUEST_CHANGES`). La policy par défaut
   `strict` dérive le verdict des findings ouverts (blocker/major ⇒
   request_changes) ; l'enforcement fail-closed (couverture partielle,
   evidence blocker, tool failure) force `request_changes`.
2. Le job `review-pr` expose `verdict`, `review-result`, `verdict-source`
   en **outputs de job**.
3. Un nouveau job `auto-merge` (`needs: review-pr`) fait `gh pr merge
   --squash` si TOUTES les gardes sont vraies :

| Garde | Raison |
|---|---|
| `verdict == approve` **et** `review-result ∈ {clean, findings}` | Règle vendor : un `approve` avec `review-result: partial` (investigation incomplète) n'est PAS un feu vert — jamais le verdict seul. |
| auteur `mushu-bot[bot]` | L'AI ne merge jamais une PR humaine. |
| branche `renovate/*` et **pas** `renovate/am-*` | Les `am-*` sont déjà automergés par Renovate et leur review est skippée. |
| sans label `type/major`, sans `!` dans le titre | Pas d'automerge de major (défense en profondeur, en plus de la règle Renovate). |
| aucun fichier matchant `^talos/` ni `kubernetes/apps/system-upgrade/` | Pas d'upgrade Talos / Kubernetes automatique (tuppr inclut les bumps k8s). Vérifié par `actions/github-script` (paths listFiles), fail-closed. |
| tous les status checks SUCCESS/SKIPPED/NEUTRAL (loop 25 min max) | Ne merger que sur CI verte (ci-status de la review n'attend pas les checks secondaires comme image-pull). |

4. Tokens : le job review garde `contents: read` (review dirigée par le
   modèle, read-only) ; seul le job `auto-merge` mint un token
   `contents: write` pour le merge (least privilege, erreur de passe
   corrigée suite à la review AI de la PR). Fail-closed naturel : si le
   verdict ne sort pas à l'approve, rien ne se passe et la PR reste à
   merger à la main. Le loop d'attente des checks exclut le check run du
   job lui-même (IN_PROGRESS par définition) — sinon `pending` ne tombait
   jamais à 0 et le merge était inatteignable (deadlock, review AI).
5. `workflow_dispatch` (re-review manuel) : ne déclenche JAMAIS le merge
   (`github.event_name == 'pull_request'` requis) — un verdict obtenu à la
   main ne fusione pas hors contexte standard.

## Non-goals

- Pas de branch protection sur `main` (option 1 refusée : change le merge
  flow de toutes les PRs, y compris humaines).
- Pas d'automerge `github-release` générique : seule `jdx/mise` (PR #5192)
  est programmée.
- Le label `automerge` n'est plus émis (chantier 1 fix par préfixe de
  branche) ; il reste déclaré dans `labels.yaml` pour usage ultérieur.

## Validation

1. `python3 -c "import yaml..."` sur le workflow (parse + clés présentes).
2. Schema action : digest d'action changéo (`actions/github-script@v9`).
   Le `uses` de nouveaux greffons doivent passer `zizmor` (pin-ash digest ✅).
3. Observation : la prochaine PR Renovate core patch/minor doit être mergée
   par le job `auto-merge` (~5 min après la review).

## Rollback

Revert de la PR unique ; niveau token, l'App garde contents/write (déjà
présent avant), et un job `auto-merge` inactif ne peut merger que si le
verdict-sortie redevien vert sur un futur run — rien à purger côté cluster.
