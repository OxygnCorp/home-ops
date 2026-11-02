# OpenCost — Cost Allocation & Hyperscaler What-If

**Date:** 2026-10-28
**Status:** Approved design, pending implementation plan
**Namespace:** `observability` · **Chart:** `oci://ghcr.io/opencost/charts/opencost` @ `2.5.33`

## Goal

Install **OpenCost OSS** (CNCF sandbox project, sponsored by Kubecost) to provide:

1. Per-namespace / per-workload resource cost breakdown
2. An "AWS us-east-1 equivalent" pricing model for this on-prem cluster (user-selected reference)
3. Metrics exposed to Prometheus so that the `radar` MCP server's `get_cost` tool becomes functional (currently `no_cost_source`)

An earlier evaluation compared OpenCost OSS vs Kubecost commercial vs an embedded Prometheus; **OpenCost OSS wired to the existing Prometheus was chosen and approved** (A), with approaches B (bundled Prometheus) and C (Kubecost commercial) rejected.

## Verified prerequisites (live cluster checks, 2026-10-28)

- Prometheus (kube-prometheus-stack, "prompp" v3 image) at `kube-prometheus-stack-prometheus.observability` — required by OpenCost
- **kube-state-metrics present** (`kube_pod_container_resource_requests`, `kube_node_info`, `kube_persistentvolumeclaim_info` in Prometheus) — despite `kubeStateMetrics.enabled: false` in the kube-prometheus-stack HelmRelease, KSM is deployed separately; OpenCost's data sources are satisfied
- cAdvisor metrics present (`container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`)
- **No GPU metrics** (no DCGM exporter scraped; `.*nvidia.*|.*gpu.*` → 0 series). GPU cost will be modeled at node level, not utilization
- Cluster capacity: 4 nodes, ≈32 vCPU / ~142 GiB allocatable + 1 NVIDIA GPU node (`k8s-3`)

## File layout (follows `blackbox-exporter` conventions, NOT app-template)

OpenCost is a multi-component chart (exporter + UI + MCP) with native ServiceMonitor/HTTPRoute values — the app-template wrapper is not appropriate here, matching the other observability apps that deploy vendor charts directly.

```
kubernetes/apps/observability/opencost/
├── ks.yaml                    # Flux Kustomization: targetNamespace observability, interval 1h, wait false
└── app/
    ├── kustomization.yaml     # ocirepository.yaml + helmrelease.yaml
    ├── ocirepository.yaml     # oci://ghcr.io/opencost/charts/opencost, ref.tag 2.5.33
    ├── helmrelease.yaml
    └── grafanadashboard.yaml  # OpenCost dashboards via grafana-operator CRD (datasourceName: prometheus)
```

**Plus:** add `./opencost/ks.yaml` to `kubernetes/apps/observability/kustomization.yaml` (add-app skill Step 4).

## HelmRelease configuration

Standard Flux block per repo conventions: `interval: 1h`, `chartRef` → OCIRepository, `install.remediation.retries: -1`, `upgrade.cleanupOnFail: true` + `retries: 3`, inline values, resources requests/limits, no inline `metadata.namespace` (namespace injected by app `kustomization.yaml`).

Key values:

```yaml
opencost:
  prometheus:
    internal:
      enabled: false
    external:
      enabled: true
      url: http://kube-prometheus-stack-prometheus.observability.svc.cluster.local:9090
  metrics:
    serviceMonitor:
      enabled: true          # exposes opencost_* metrics → radar-get_cost
  customPricing:
    enabled: true
    createConfigmap: true
    costModel:
      description: AWS us-east-1 on-demand reference (m5-class compute, EBS gp3)
      CPU: "0.048"           # $0.192/hr m5.xlarge ÷ 4 vCPU
      spotCPU: "0.0144"      # ~70% discount
      RAM: "0.012"           # $0.192/hr ÷ 16 GiB
      spotRAM: "0.0036"
      GPU: "0.95"            # g5/A10G class (OpenCost default)
      storage: "0.0001096"   # EBS gp3 $0.08/GiB-month ÷ 730 h
      zoneNetworkEgress: "0.01"
      regionNetworkEgress: "0.01"
      internetNetworkEgress: "0.12"
  ui:
    httpRoute:
      enabled: true
      parentRefs:
        - name: envoy-internal
          namespace: network
      hostnames: ["opencost.oxygn.dev"]
  mcp:
    enabled: true            # chart default; served on port 8081, NOT exposed via route
```

Notes:

- Pricing units are **hourly USD** (OpenCost `default.json` uses hourly rates; chart `customPricing.costModel` maps to the same format). Exact numeric values must be sanity-checked after deploy: cluster total ≈ $2 000–3 500/month order of magnitude.
- HTTPRoute is handled natively by the chart (`opencost.ui.httpRoute`) — no standalone route manifest needed.
- `mcp.httpRoute` (port 8081) stays unexposed; radar reads cost data through Prometheus, not through OpenCost MCP.
- Uses the chart's default pinned image digests (exporter 1.121.3, UI 1.121.3).
- Chart NetworkPolicies left disabled (default); revisit only if actual scraping fails.

## Grafana dashboards

`grafanadashboard.yaml` following the `kube-prometheus-stack/app/grafanadashboard.yaml` pattern: `allowCrossNamespaceImport: true`, `instanceSelector.matchLabels: grafana.internal/instance: grafana`, `datasources: datasourceName: prometheus`. Identify the official OpenCost dashboard(s) on grafana.com at implementation time and pin by URL + revision.

## Known limitations (accepted)

1. **No GPU metrics**: GPU cost charged at node level (allocation), not utilization. Optional follow-up (out of scope): deploy dcgm-exporter.
2. Prometheus retention is 30d / 45GB: OpenCost series add modest cardinality; OpenCost ETL/write-to-Prometheus not enabled (YAGNI).
3. On-prem costs are notional: value is right-sizing / noisy-neighbor detection / priority arbitration, not a real invoice. Storage class `miroir-slow` (DRBD) is not EBS — cost is reference-based.
4. OpenCost pods schedule on control-plane nodes (no toleration for `k8s-3` taint) — consistent with the rest of the observability stack.

## Validation

- Local: `mise exec -- flate test hr --path ./kubernetes/apps/observability/opencost` and `flate test ks`; plus `helm template` sanity render of chart + values before commit.
- Pre-merge: rendered manifest diff via the flux MCP `diff_kubernetes_manifest` (owner: new HelmRelease `opencost @ observability`).
- Post-merge: HelmRelease Ready → Prometheus target `up` for the opencost ServiceMonitor → `radar-get_cost` returns `available: true` with per-namespace summary consistent with capacity → UI reachable at `opencost.oxygn.dev` → dashboards render.

## Out of scope

- dcgm-exporter / GPU utilization pricing
- OpenCost cloud integrations (AWS/GCP/Azure billing ingestion) — meaningless on-prem
- Long-term cost storage beyond Prometheus 30d retention
