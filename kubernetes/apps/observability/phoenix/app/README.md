# Phoenix

[Arize Phoenix](https://arize.com/docs/phoenix/self-hosting) self-hosted: the
cluster's LLM/agent observability backend (traces, evals, prompt iteration).
Runs on the official `arizephoenix/phoenix-helm` chart (pinned `13.0.0` via
`OCIRepository`), external-DB strategy (no in-chart postgres, no SQLite).

- **UI/API**: `https://phoenix.oxygn.dev` — Envoy Gateway `HTTPRoute` gated by
  Kanidm OIDC (`components/oidc-kanidm/envoy`, client `phoenix`). The chart's
  Ingress is disabled.
- **OTLP ingestion** (cluster-internal only, authenticated by a Phoenix
  system key): HTTP on `phoenix-svc.observability.svc.cluster.local:6006`
  (`/v1/traces`, same port as the UI) and gRPC on
  `phoenix-svc.observability.svc.cluster.local:4317`. The Service is named
  `phoenix-svc` by the chart — there is **no port 4318**; Prometheus metrics
  are on `:9090`.
- Phoenix is **not on the request path** of instrumented apps: OTLP exporters
  buffer and drop batches when it is down.

## Credentials (1Password item `phoenix`)

| Field | Purpose |
| ----- | ------- |
| `PHOENIX_SECRET` | Phoenix token-signing secret |
| `PHOENIX_DEFAULT_ADMIN_INITIAL_PASSWORD` | built-in admin first login |
| `PHOENIX_SYSTEM_API_KEY` | ingestion system key, created in the Phoenix UI post-deploy (Settings → API Keys → system key) |

- `ExternalSecret phoenix` → Secret `phoenix-secret`, consumed by the
  HelmRelease as deploy env.
- `ExternalSecret phoenix-otel` → Secret `phoenix-otel`, exposes
  `OTEL_EXPORTER_OTLP_HEADERS` ready for exporters. Stays in
  `SecretSyncedError` until `PHOENIX_SYSTEM_API_KEY` is added to the item.

## Postgres

Provisioned by `components/postgres`: CNPG Cluster `phoenix` (net-new
initdb — the `components.postgres/cnpg: init` label on the ks must be removed
after the first Barman backup, see the component README). Trace retention is
90 days (`database.defaultRetentionPolicyDays: 90`); datasets, annotations
and experiments are **not** purged.

## Wiring an exporter (Tasks 2-3)

```yaml
OTEL_EXPORTER_OTLP_ENDPOINT: http://phoenix-svc.observability:6006  # SDKs append /v1/traces
OTEL_EXPORTER_OTLP_HEADERS: <from Secret phoenix-otel>
OTEL_RESOURCE_ATTRIBUTES: openinference.project.name=<app>
```

litellm's per-key-alias project segmentation is documented in Task 2.

## Day-1 wiring: litellm exports OTLP → Phoenix

litellm ships instrumented from day one (Task 2):
`kubernetes/apps/ai/litellm/app/litellmproxy.yaml` adds the native
`otel` callback to `litellmSettings.success_callback`/`failure_callback`
and the `OTEL_EXPORTER_OTLP_*` env vars from the recipe above; the auth
header comes from litellm's own copy of the `phoenix-otel` ExternalSecret
(`kubernetes/apps/ai/litellm/app/externalsecret.yaml`). Spans land in the
default project (dedicated `litellm` project rejected as MVP). The exact
span attribute carrying the litellm virtual-key alias — the per-agent
segmentation basis for evals (Task 4 / spec §4.2/§6) — is to be captured
from a span in the Phoenix UI during the deferred post-merge smoke test
and recorded here.

## Out of MVP scope

- central OTel Collector (spec §9)
- app-level instrumentation for non-MVP apps (spec §4.3)
- Grafana dashboards correlating litellm ↔ Phoenix (spec §9)

## Phoenix-level OAuth2 (deliberately disabled)

App-level OIDC (`auth.oauth2`, `PHOENIX_OAUTH2_*`) is intentionally not
enabled — the Envoy SecurityPolicy already fronts the UI. Revisit only if
(a) it becomes useful and (b) Kanidm support is confirmed (spec §6).
