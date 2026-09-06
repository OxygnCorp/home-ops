# MCP unifi-network pour devclaw — Design

**Date :** 2026-09-06
**Statut :** Approuvé (design présenté et validé en session)

## Objectif

Exposer le contrôleur UniFi (`unifi.internal`) comme serveur MCP `unifi-network` dans toolhive, consommé par l'agent **devclaw** via le gateway `vmcp-mcp-gateway-devops` (groupe `mcp-devops`).

Basé sur le déploiement de référence [joryirving/home-ops](https://github.com/joryirving/home-ops/blob/main/kubernetes/apps/base/llm/toolhive/mcp-servers/unifi-network-mcp/mcpserver.yaml), avec adaptations :

- `groupRef: mcp-devops` (référence : `mcp-tools`) — devclaw consomme `mcp-gateway-devops`
- Contrôleur : `unifi.internal`, site `default`
- Identifiants : item 1Password **`unifi`** (champs `username`/`password`) → un seul secret `toolhive-unifi-network` avec clés `UNIFI_NETWORK_USERNAME`/`UNIFI_NETWORK_PASSWORD` (référence : deux secrets séparés)
- Permissions lecture seule : `UNIFI_TOOL_REGISTRATION_MODE=meta_only`, `UNIFI_POLICY_{CREATE,UPDATE,DELETE}=false`, `UNIFI_TOOL_PERMISSION_MODE=confirm`
- Image pin digest : `ghcr.io/sirkirby/unifi-network-mcp:0.29.7@sha256:3307ada7db311203ea1802993bf3fcc022d14966434c4b740e7d0a8e3351ca72`

## Changements

| Fichier | Action |
|---|---|
| `kubernetes/apps/ai/toolhive/mcp-servers/unifi-network-mcp/mcpserver.yaml` | Nouveau — `MCPServer` `unifi-network`, `streamable-http`, port 3000, resources 100m/128Mi → 200m/256Mi |
| `kubernetes/apps/ai/toolhive/mcp-servers/unifi-network-mcp/externalsecret.yaml` | Nouveau — `ExternalSecret` `toolhive-unifi-network` (ClusterSecretStore `onepassword`, extract `unifi`) |
| `kubernetes/apps/ai/toolhive/mcp-servers/unifi-network-mcp/kustomization.yaml` | Nouveau |
| `kubernetes/apps/ai/toolhive/ks.yaml` | Ajout Kustomization `unifi-network-mcp` (dependsOn `toolhive`, targetNamespace `ai`) |
| `kubernetes/apps/ai/toolhive/config/mcpgroup-devops.yaml` | Description du groupe mise à jour |

## Validation

```bash
mise exec -- flate test ks --path ./kubernetes/apps/ai/toolhive
mise exec -- flate test hr --path ./kubernetes/apps/ai/toolhive
```

## Prérequis post-merge

L'item 1Password `unifi` doit exister dans le vault (champs `UNIFI_PUCHU_USERNAME` et `UNIFI_PUCHU_PASSWORD`), sinon l'`ExternalSecret` restera en `SecretSyncedError`.

## Validation effectuée

- Authentification contrôleur testée en conditions réelles depuis un pod (POST `/api/auth/login`) : OK avec le compte local `puchu@oxygn.dev` (`local_account_exist: true`). Les comptes SSO/UID Enterprise purs ne passent pas par cet endpoint (issues amont #566, #521).
- `flate test ks` sur `./kubernetes/apps/ai/toolhive` : `ai/unifi-network-mcp` ✓
