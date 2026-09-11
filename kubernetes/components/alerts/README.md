# alerts

Flux notification wiring, packaged as a reusable component. Adding it to an app's Flux Kustomization ships two independent sub-components:

| Path            | Contents                                                                    |
|-----------------|------------------------------------------------------------------------------|
| `alertmanager/` | Forwards Flux error events to Alertmanager (observability)                   |
| `github-status/`| Posts Flux reconciliation results as commit statuses on `OxygnCorp/home-ops` |

Both are `Provider` + `Alert` pairs from `notification.toolkit.fluxcd.io`; they carry no app-specific resources and are safe to include everywhere (currently used by ~20 namespaces/apps).

## alertmanager

- **Provider** `alertmanager` → Alertmanager API endpoint in `observability`.
- **Alert** `alertmanager` — `eventSeverity: error`, watching all Flux kinds in the namespace (`HelmRelease`, `Kustomization`, `OCIRepository`, `GitRepository`, `HelmRepository`, `FluxInstance`), with a standard `exclusionList` (DNS lookup blips, dial timeouts, waiting sockets).

## github-status

- **Provider** `github-status` → GitHub commit status API on `https://github.com/OxygnCorp/home-ops`, authenticated with a token from Secret `github-token-secret`.
- **ExternalSecret** `github-token` — sources the token from the 1Password item `github` (field `GITHUB_NOTIFICATION_TOKEN`) via `ClusterSecretStore onepassword`.
- **Alert** `github-status` — watches `Kustomization` sources in the namespace; default severity (`info`) means both success and error events are posted, so merged PRs show green (or red) statuses on the committing SHA.

## Usage

```yaml
spec:
  components:
    - ../../../../components/alerts
```

Alerts are scoped to the namespace of the consuming Kustomization (`eventSources` match `*` within it) — no cross-namespace noise.
