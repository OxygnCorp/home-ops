# authentik : sessions persistantes + SSO transparent — Design

**Date :** 2026-09-09
**Statut :** Approuvé

## Problème

1. **Re-login fréquents et « aléatoires »** : il faut retaper identifiants + MFA de manière imprévisible.
2. **SSO ressenti comme absent** : passer d'une app à une autre affiche un écran authentik (consentement).

## Diagnostic (vérifié contre le code source authentik 2026.8.1)

| Constat | Cause |
|---|---|
| Re-login complet « aléatoire » | Le `UserLoginStage` par défaut (`default-authentication-login`) a `session_duration: seconds=0`. Combiné à `SESSION_EXPIRE_AT_BROWSER_CLOSE=True` (codé en dur dans les settings), la session meurt à chaque fermeture du navigateur. |
| Coupable exclu | Les sessions authentik sont stockées en **Postgres** (moteur `authentik.core.sessions`), pas en Redis. Les restarts d'`authentik-dragonfly` ou des nœuds ne déconnectent personne. |
| Friction inter-apps | Les providers `mainclaw` et `opencode` utilisent le flow `default-provider-authorization-explicit-consent` (stage de consentement en mode `expiring`, 4 semaines). |
| Durées de tokens OIDC | `access_code_validity: hours=1`, `token_validity: hours=24`, `refresh_token_validity: days=30`, grant `refresh_token` activé — sain, non en cause. |

Contexte : authentik est exposé publiquement (route `authentik.oxygn.dev` sur `envoy-external`). Le login est protégé par **MFA** (validé par l'utilisateur), ce qui autorise des sessions persistantes raisonnables.

## Décisions

| Paramètre | Valeur | Justification |
|---|---|---|
| `session_duration` | `days=7` | Cookie persistant : survit à la fermeture du navigateur. 7 j sur un IdP public avec MFA. |
| `remember_me_offset` | `days=30` | Affiche la case « Se souvenir de moi » sur le formulaire de login ; prolonge la session à 30 j. |
| `authorization_flow` (providers mainclaw + opencode) | `default-provider-authorization-implicit-consent` | SSO totalement transparent : aucun écran authentik entre deux apps tant que la session vit. Adapté à un home lab. |

Écartées : changement manuel UI (drift GitOps), option minimaliste « remember me » seul (friction résiduelle).

## Changements

1. **`kubernetes/apps/security/authentik/app/blueprint.yaml`** (nouveau) — ConfigMap `authentik-blueprint` contenant un blueprint qui patche le stage de login par défaut :

   ```yaml
   entries:
     - identifiers: { name: default-authentication-login }
       model: authentik_stages_user_login.userloginstage
       attrs:
         session_duration: days=7
         remember_me_offset: days=30
   ```

2. **`kubernetes/apps/security/authentik/app/kustomization.yaml`** — ajouter `./blueprint.yaml`.

3. **`kubernetes/apps/security/authentik/app/helmrelease.yaml`** — ajouter `authentik-blueprint` à `blueprints.configMaps`.

4. **`kubernetes/apps/ai/mainclaw/blueprint/blueprint-mainclaw.yaml`** — `authorization_flow: !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]`.

5. **`kubernetes/apps/ai/opencode/blueprint/blueprint-opencode.yaml`** — idem.

## Propagation

ConfigMap modifié → `reloader.stakater.com/auto` (déjà présent via `global.podAnnotations`) redémarre les pods authentik → le worker ré-applique les blueprints (`!Find` sur les slugs par défaut, déjà présents en base).

## Validation

- **Pre-merge** : `flate test ks --path ./kubernetes/apps` et `flate test hr --path ./kubernetes/apps` + diff contre `main`.
- **Post-merge** :
  1. Se connecter à authentik (identifiants + MFA), cocher « Se souvenir de moi ».
  2. Fermer puis rouvrir le navigateur → toujours authentifié.
  3. Naviguer de `mainclaw.oxygn.dev` à `opencode.oxygn.dev` → aucune interception par authentik.

## Sécurité

- Fenêtre de session : 7 j (30 j avec remember me) sur un IdP public — accepté avec MFA actif.
- Le stage `default-authentication-login` conserve `terminate_other_sessions: false`, `network_binding`/`geoip_binding` non configurés ; ils restent des leviers durcissables plus tard sans nouveau design.
