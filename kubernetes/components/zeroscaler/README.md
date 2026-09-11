# zeroscaler

Scale-to-zero on idle for low-traffic workloads, via a single `HorizontalPodAutoscaler` (min `0` / max `1` replica) driven by an external Prometheus probe metric. Used by the `download` and `media` apps (plex, arr stack, qbittorrent, tautulli, …).

## Behavior

- **Metric**: `External` metric `${ZEROSCALER_METRIC_NAME:=probe_success}` from Prometheus job `${ZEROSCALER_JOB_NAME:=nfs_probe}` (exposed through the prometheus-adapter). The probe tracks the app's backing storage availability — when the NFS export is unreachable, `probe_success` drops to `0` and the HPA scales the workload to zero instead of letting it crash-loop against dead storage.
- **Scale down**: to `0` replicas as soon as the probe fails (no stabilization window).
- **Scale up**: back to `1` replica when the probe recovers (15s periods, no stabilization window).
- HPAScaleToZero is enabled cluster-wide (see the `HPAScaleToZero=true` feature gate in the Talos control-plane config).

## Substitution variables

| Variable                  | Default         | Notes                                              |
|---------------------------|-----------------|----------------------------------------------------|
| `APP`                     | _(required)_    | Name of the HPA and of the target workload.        |
| `CONTROLLER`              | `Deployment`    | `scaleTargetRef` kind.                             |
| `ZEROSCALER_METRIC_NAME`  | `probe_success` | External metric consulted by the HPA.              |
| `ZEROSCALER_JOB_NAME`     | `nfs_probe`     | Prometheus job label the metric is selected on.    |

## Usage

```yaml
spec:
  components:
    - ../../../../components/zeroscaler
```

The workload must tolerate scaling to zero (no in-cluster writers, no long-lived local state) — it is meant for idle-tolerant media/download apps, not databases.
