# konflate MCP pour devclaw — Design

**Date**: 2026-08-30
**Status**: Approved (en conversation)
**Dépend de**: konflate déployé (PR #4099, mergée)

## Contexte

L'agent devclaw consomme les MCP via toolhive : `openclaw.json` → `vmcp-mcp-gateway-devops`
(VirtualMCPServer, groupe `mcp-devops`) → serveurs. konflate expose un endpoint MCP
read-only (`/mcp`, streamable-http) avec `list_pull_requests`, `get_pr_summary`,
`get_pr_diff` — le blast radius rendu des PRs, exactement ce qu'il faut pour les reviews
de l'agent (workflow AGENTS.md).

## Décisions

- **Pattern** : `MCPServerEntry` (endpoint HTTP distant), comme grafana/radar/teslamate.
- **Chemin** : `kubernetes/apps/ai/toolhive/mcp-servers/konflate-mcp/` avec
  `kustomization.yaml` + `mcpserverentry.yaml` ; enregistrement via un bloc
  `konflate-mcp-entry` dans `kubernetes/apps/ai/toolhive/ks.yaml`
  (`dependsOn: toolhive` + `konflate`/flux-system).
- **Entry** : `remoteUrl: http://konflate.flux-system:8080/mcp`,
  `transport: streamable-http`, `groupRef: mcp-devops`.
- Les outils apparaîtront préfixés `konflate_` (agrégation vmcp `{workload}_`).
- Pas de secret, pas de RBAC (endpoint interne anonyme), pas de pod supplémentaire.

## Validation

`mise exec -- flate test ks --path ./kubernetes/apps/ai` ; post-merge :
`kubectl get mcpserverentry konflate -n ai` (PHASE Valid) puis vérifier
`konflate_list_pull_requests` côté devclaw.
