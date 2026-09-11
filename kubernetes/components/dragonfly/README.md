# dragonfly

[DragonflyDB](https://github.com/dragonflydb/dragonfly) (Redis-compatible in-memory store) cache for apps, packaged as a reusable component. Adding it to an app's Flux Kustomization creates a dedicated 2-replica Dragonfly cluster in the app's namespace and wires the dependency on the operator.

## What gets created

- **`Dragonfly`** `${APP}-dragonfly` — image `ghcr.io/dragonflydb/dragonfly:v1.40.2`, 2 replicas with `--cluster_mode=emulated`, `MAX_MEMORY` derived from the pod memory limit (`limits.memory: 768Mi`), `proactor_threads=2`, `allow-undeclared-keys` Lua flags, topology spread across hostnames (honoring taints).
- **`PodMonitor`** — Prometheus metrics scraping for the Dragonfly pods.
- **`NetworkPolicy`** — restricts metrics scraping to Prometheus.
- **Patch** on the consuming `HelmRelease` — adds `spec.dependsOn: dragonfly-operator` (namespace `database`), so the operator is healthy before the app reconciles.

## Usage

```yaml
spec:
  components:
    - ../../../../components/dragonfly
  dependsOn:
    - name: toolhive
  healthCheckExprs:
    - apiVersion: dragonflydb.io/v1alpha1
      kind: Dragonfly
      failed: status.phase != 'ready'
      current: status.phase == 'ready'
  postBuild:
    substitute:
      APP: *name
```

`APP` is the only substitution variable; the cluster is named `${APP}-dragonfly`. Point the app's cache/redis URL at the `${APP}-dragonfly` service (client port `6379`).

> Not to be confused with the Dragonfly P2P image distribution project — this component is the DragonflyDB cache only. Image distribution on this cluster is handled by [spegel](https://github.com/spegel-org/spegel).
