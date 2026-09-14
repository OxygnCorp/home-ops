# oidc

Per-app OIDC single sign-on against Authentik, extracted from the duplicated per-app `blueprint/` + `app/securitypolicy.yaml` pattern (mainclaw, opencode). Pattern inspired by eleboucher's kanidm `oidc` component, adapted to Authentik blueprints, Envoy Gateway, and flate's offline discovery (the thin `ks-blueprint.yaml` glue stays per-app so the dependency graph stays visible to flate).

Two sub-directories:

| Path        | Kind                | Contents                                                                                                                                                       |
|-------------|---------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `blueprint/`| shared template     | Authentik blueprint `ConfigMap` (`${APP}-blueprint`, namespace `security`): `OAuth2Provider` + `Application`. Built by each app's `ks-blueprint.yaml`, never included directly. |
| `envoy/`    | kustomize Component | Envoy Gateway `SecurityPolicy` `${APP}-oidc` — OIDC authentication in front of the app's `HTTPRoute`. Included via `spec.components`.                           |

## What gets created

- **`ConfigMap/${APP}-blueprint`** (namespace `security`) — Authentik blueprint: `OAuth2Provider` (`client_id`/`client_secret` from `!Env` injected into the authentik worker via `apps/security/authentik/app/externalsecret.yaml`) + `Application` (slug `${APP}`, display name `${OIDC_DISPLAY_NAME}`).
- **`SecurityPolicy` `${APP}-oidc`** (app namespace) — OIDC authn against `https://authentik.<domain>/application/o/${APP}/`, secret `${APP}-oidc`, redirect `https://<subdomain>.<domain><callback>`.

Names are preserved from the pre-component layout, so the `authentik` Flux Kustomization `dependsOn` (`mainclaw-blueprint`, `opencode-blueprint`) and the authentik HelmRelease `blueprints.configMaps` list keep working unchanged.

## Substitution variables

`blueprint/` (set in the app's `ks-blueprint.yaml`):

| Variable            | Default            | Notes                                                                                          |
|---------------------|--------------------|------------------------------------------------------------------------------------------------|
| `APP`               | _(required)_       | App/slug/provider name — must match the 1Password item and the authentik ExternalSecret env.   |
| `OIDC_DISPLAY_NAME` | _(required)_       | Human display name (`MainClaw`, `OpenCode`, …).                                                |
| `OIDC_ENV_PREFIX`   | _(required)_       | Uppercase prefix of the authentik worker env vars (`MAINCLAW`, `OPENCODE`, …).                 |
| `SUBDOMAIN`         | `${APP}`           | Public hostname prefix.                                                                        |
| `DOMAIN`            | `oxygn.dev`        | Cluster public domain.                                                                         |
| `OIDC_CALLBACK`     | `/oauth2/callback` | Redirect URI path.                                                                             |

`envoy/` (set in the app's `ks.yaml` `postBuild.substitute`):

| Variable          | Default            | Notes                                                          |
|-------------------|--------------------|-----------------------------------------------------------------|
| `APP`             | _(required)_       | Usually already present.                                        |
| `SUBDOMAIN`       | _(required)_       | Public hostname prefix.                                         |
| `OIDC_ROUTE_NAME` | _(required)_       | `HTTPRoute` name targeted by the SecurityPolicy.                |
| `DOMAIN`          | `oxygn.dev`        | Cluster public domain.                                          |
| `OIDC_CALLBACK`   | `/oauth2/callback` | Redirect URI path.                                              |

## Onboarding a new app

1. Create the 1Password item `<app>` with fields `<APP>_CLIENT_ID` / `<APP>_CLIENT_SECRET` (uppercase, matching `OIDC_ENV_PREFIX`).
2. Add `<APP>_CLIENT_ID` / `<APP>_CLIENT_SECRET` to `apps/security/authentik/app/externalsecret.yaml` (worker `!Env` source) and to the app's own `externalsecret.yaml` (secret `${APP}-oidc`, keys `client-id`/`client-secret` for the SecurityPolicy).
3. Add `<app>-blueprint` to `blueprints.configMaps` in `apps/security/authentik/app/helmrelease.yaml` and to `dependsOn` in `apps/security/authentik/ks.yaml`.
4. Add a thin `ks-blueprint.yaml` next to the app's `ks.yaml` (see `apps/ai/mainclaw/ks-blueprint.yaml`) and list it in `apps/ai/kustomization.yaml`.
5. In the app's `ks.yaml`:

```yaml
spec:
  components:
    - ../../../../components/oidc/envoy
  postBuild:
    substitute:
      APP: myapp
      SUBDOMAIN: myapp
      OIDC_ROUTE_NAME: myapp
```

6. There is no per-app `blueprint/` directory or `app/securitypolicy.yaml` anymore.

## Troubleshooting

Envoy Gateway does not retry failed OIDC discovery. If a policy is created before the Authentik provider exists, discovery 404s permanently — after the blueprint has reconciled, nudge a re-translation with a no-op annotation change on the `SecurityPolicy`.