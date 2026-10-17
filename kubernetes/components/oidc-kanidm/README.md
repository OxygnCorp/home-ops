# oidc-kanidm

Per-app OIDC single sign-on against Kanidm, built from eleboucher's
`components/oidc` (git.erwanleboucher.dev) and adapted to this repo's naming.
Replaces the previous Authentik-based `components/oidc` (blueprint
ConfigMaps + `${APP}-oidc` secrets from 1Password).

## Sub-directories

| Path     | Kind                | Contents                                                                                                                            |
|----------|---------------------|--------------------------------------------------------------------------------------------------------------------------------------|
| `base/`  | shared template     | Flux Kustomization `kanidm-${APP}-oidc` (namespace `security`, `dependsOn`: kanidm) applying the kanidm-provision ConfigMap for this app. Included transitively by every consumer below. |
| `envoy/` | kustomize Component | `../base` + Envoy Gateway `SecurityPolicy` `${APP}-oidc` (OIDC in front of the app's HTTPRoute). Included via `spec.components`.       |

## What gets created

- **Flux Kustomization `kanidm-${APP}-oidc`** (namespace `security`) — applies
  `base/kanidm/`, i.e. a **ConfigMap `kanidm-${APP}-oidc`** labeled
  `kanidm_config: "1"`: the declarative OAuth2 client state
  (`state.json`, kanidm-provision schema) consumed by the
  `provision` controller of `apps/security/kanidm`.
- **Secret `kanidm-${APP}-oidc`** (app namespace, keys `client-id` /
  `client-secret`) — written by the provision controller via its API token;
  nothing to store in 1Password per app.
- **SecurityPolicy `${APP}-oidc`** (app namespace) — OIDC authn against
  `https://idm.oxygn.dev/oauth2/openid/${APP}`. Authorization and token
  endpoints are pinned explicitly so Envoy never re-discovers through the
  gateway during Kanidm TLS-certificate rollouts (Envoy Gateway does not
  retry a failed discovery).

## Substitution variables

Set on the consuming app's `ks.yaml`. **Required** (the component renders
empty values without them, and the app KS then never reconciles):

| Variable        | Example       | Notes                                        |
|-----------------|---------------|----------------------------------------------|
| `APP`           | `mainclaw`    | Client slug and client ID in Kanidm          |
| `APP_NAMESPACE` | `ai`          | Where the `kanidm-${APP}-oidc` Secret lands  |
| `SUBDOMAIN`     | `mainclaw`    | Public hostname prefix                       |
| `DOMAIN`        | `oxygn.dev`   | Public domain                                |
| `OIDC_DISPLAY_NAME` | `MainClaw`| Human display name                           |
| `OIDC_CALLBACK` | `/oauth2/callback` | Redirect URI path                      |
| `OIDC_ROUTE_NAME`   | `mainclaw-main` | HTTPRoute targeted by the SecurityPolicy (`envoy/` only) |

Optional (defaults shown): `OIDC_ORIGIN` `/`, `OIDC_SHORT_USERNAME` `false`,
`OIDC_GROUP` `users`, `OIDC_SCOPES` `["openid", "profile", "email", "groups"]`,
`OIDC_CLIENT_ID_KEY`/`OIDC_CLIENT_SECRET_KEY` `client-id`/`client-secret`.

Defaults must stay free of `${}` nesting — Flux's envsubst expands `:=`
defaults exactly once (nested placeholders render as `null`; verified with
`flate`).

## Onboarding a new app

In the app's `ks.yaml`:

```yaml
spec:
  components:
    - ../../../../components/oidc-kanidm/envoy
  dependsOn:
    - name: kanidm
      namespace: security
  postBuild:
    substitute:
      APP: myapp
      APP_NAMESPACE: myns
      DOMAIN: oxygn.dev
      OIDC_CALLBACK: /oauth2/callback
      OIDC_DISPLAY_NAME: MyApp
      OIDC_ROUTE_NAME: myapp
      SUBDOMAIN: myapp
```

No 1Password item and no blueprint Kustomization needed — the provisioner
creates the Kanidm client and its Secret from the ConfigMap. For in-app OIDC
(the app consumes the provider itself rather than through Envoy), use
`../../../../components/oidc-kanidm/base` and read
`client-id` / `client-secret` from the Secret `kanidm-${APP}-oidc`.

## Troubleshooting

An Envoy `SecurityPolicy` does not re-run discovery: if it translated before
the Kanidm client (or its Secret) existed, nudge a re-translation with a
no-op annotation change on the `SecurityPolicy`. The pinned authorization
/token endpoints protect against discovery-path failures during Kanidm
TLS rollouts, not against a missing client Secret.
