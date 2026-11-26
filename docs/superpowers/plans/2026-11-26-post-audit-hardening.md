# Post-audit hardening — offsite backups, Talos system logs, tracing, BGP timers

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the four gaps identified in the 2026-11-26 audit of `eleboucher/homelab`: backups only exist on one NFS export, Talos system services (etcd/kubelet/containerd) produce no retained logs, the cluster has no tracing backend, and BGP failover is bounded by 90 s default timers.

**Architecture:** Each phase is an independent, separately mergeable PR; nothing here shares state with another phase. Offsite backups promote a new S3 `ClusterRepository` to be the `SnapshotPolicy` target — seeded once from the existing NFS repository, which is then frozen read-only — so 3-2-1 is achieved by configuration rather than by a second copy job. System logs ride Talos `machine.logging.destinations` into a host-network fluent-bit DaemonSet that forwards to the existing VictoriaLogs. Tracing is a single-node `victoria-traces-single` plus a Grafana datasource. BGP timers are one block in the existing `CiliumBGPPeerConfig`.

**Tech Stack:** Flux `HelmRelease`/`Kustomization`/`ExternalSecret`, kopiur `ClusterRepository`/`SnapshotPolicy`, Cloudflare R2 (S3 API), VictoriaLogs + VictoriaTraces (OCI charts from `ghcr.io/victoriametrics/helm-charts`), fluent-bit (`ghcr.io/fluent/helm-charts/fluent-bit`), Talos machine config via `topf`, Cilium BGP control plane, `flate` for local validation.

**Spec:** this document (audit conclusions in "Baseline facts" and "Out of scope"); source audit = commits of `git.erwanleboucher.dev/eleboucher/homelab` between 2026-10-26 and 2026-11-26.

## Global Constraints

- **GitOps only.** Never `kubectl apply/edit/patch` a Flux-managed resource. Every change is a Git commit on a branch + PR, merged squash. Cluster verification commands are read-only.
- **Namespace injection.** Never set `metadata.namespace` on `HelmRelease`/`Kustomization`; the per-app `kustomization.yaml` `namespace:` (or `ks.yaml` `targetNamespace`) supplies it.
- **Secrets.** Only via `ExternalSecret` + `ClusterSecretStore onepassword`. No plaintext in Git, no `kubectl create secret` except `--dry-run` previews.
- **Storage classes.** Only `miroir-slow` (replicated, default) and `miroir-slow-local` (unreplicated). Snapshot class `miroir`.
- **Validate before push:** `mise exec -- flate test ks --path ./kubernetes/apps` and `mise exec -- flate test hr --path ./kubernetes/apps`.
- **Talos changes:** edit `talos/main/*.yaml.j2`, then `just talos render-config <node>` and `just talos apply-node <node>`. Never patch a live machine config.
- **kopiur mover identity stays `1024:100`** (`KOPIUR_PUID/PGID`): it matches the NFS export's squash target and reading source PVCs. The S3 repository does not change this.
- **Commit messages:** conventional commits, scope = app or component (`feat(kopiur): …`, `feat(observability): …`, `feat(talos): …`, `feat(network): …`).

## Baseline facts (verified 2026-11-26, do not re-derive)

- 6 CNPG clusters, **all `instances: 3`, all `readyInstances: 3`**: `ai/n8n`, `ai/lightrag`, `ai/litellm`, `automation/teslamate`, `self-hosted/forgejo`, `self-hosted/ghostfolio`. There is **no `database` namespace** — any CNPG alert must be scoped per-cluster, not to a namespace literal.
- Both gateway Services allocate NodePorts: `envoy-external` → 30952 (80/TCP), 32127 (443/TCP + 443/UDP); `envoy-internal` → 30439 (80/TCP), 31617 (443/TCP + 443/UDP). `allocateLoadBalancerNodePorts: true` on both. Nothing dials a NodePort (cloudflare-tunnel targets `https://envoy-external.network.svc.cluster.local:443` (ClusterIP)).
- **Pod logs already ship**: `kubernetes/apps/observability/victoria-logs/collector` runs chart `victoria-logs-collector` 0.3.9 with `kubernetesCollector` and remote-writes to `victoria-logs.observability.svc:9428`. What is missing is **Talos system logs** (etcd/kubelet/containerd/syslogd): `talos/main/cluster.yaml.j2` has no `machine.logging` block at all.
- No tracing stack anywhere (`tempo`, `jaeger`, `otel-collector` absent from `kubernetes/`).
- Grafana datasources use `instanceSelector.matchLabels: {grafana.internal/instance: grafana}` (**not** `dashboards: grafana`).
- `KOPIUR_REPOSITORY` default is `nas`; `nas` `ClusterRepository` is `mode: ReadWrite`, `create.enabled: false`, NFS `funkstation.internal:/volume1/Volsync` (repo path `/mnt/repository`), full maintenance daily `0 3 * * *`.
- Existing 1Password item `cloudflare` holds `CLOUDFLARE_R2_ACCESS_KEY_ID` / `CLOUDFLARE_R2_SECRET_ACCESS_KEY`; CNPG uses them against R2 endpoint `https://d1403fac4607ccda8f0f9d8153b6c03f.eu.r2.cloudflarestorage.com`.
- One BGP peer: `CiliumBGPPeerConfig l3-bgp-peer-config` (ASN 64514 → 64513 `unifi`) in `kubernetes/apps/kube-system/cilium/app/networking.yaml`, **no `timers` block** (defaults: hold 90 s, keepalive 30 s).
- Talos: kubelet image `v1.37.2`; sysctls block in `talos/main/cluster.yaml.j2` (~line 75); Jinja2 templates rendered by `topf`/`minijinja`.

## Phase 0 — Quick wins (separate PR, not detailed here)

Merge before or independently of phases 1-4; each is a one-line diff:

1. `allocateLoadBalancerNodePorts: false` in `EnvoyProxy.spec.provider.kubernetes.envoyService` (`kubernetes/apps/network/envoy-gateway/app/envoy.yaml`).
2. `NoStreamingReplica` alert, **per-cluster** scoped, in `kubernetes/apps/database/cloudnative-pg/cluster/prometheusrule.yaml`.
3. `net.ipv4.tcp_rfc1337: "1"` + `net.core.netdev_max_backlog: "16384"` in `talos/main/cluster.yaml.j2`.
4. `statefulset.podManagementPolicy: Parallel` for `security/kanidm` and `automation/mosquitto`.
5. `dial.*tcp.*unreachable` in `kubernetes/components/alerts/alertmanager/alert.yaml` `exclusionList`.
6. `reloader.reloadStrategy: annotations` in `kubernetes/apps/kube-system/reloader/app/helmrelease.yaml`.

---

## Phase 1 — Offsite kopiur repository (S3/R2)

**Deliverable:** a second `ClusterRepository` `offsite` holds every app's snapshots; the NFS repository `nas` is frozen `ReadOnly` as a local archive.

**Why R2 and not a second NAS/NFS:** the repository must survive the loss of the house, not just the cluster. R2 has no egress fee, which keeps restore drills free; the account and credentials pattern already exist for CNPG.

**Files:**
- Create: `kubernetes/apps/kopiur-system/kopiur/repository/offsite-clusterrepository.yaml`
- Create: `kubernetes/apps/kopiur-system/kopiur/repository/offsite-externalsecret.yaml`
- Modify: `kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml`
- Modify: `kubernetes/components/kopiur/backup/snapshotpolicy.yaml` (default `KOPIUR_REPOSITORY`)
- Modify: `kubernetes/components/kopiur/README.md` (variable table + design notes)
- Modify: `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml` (freeze `nas`, task 1.5)

**Interfaces:**
- Produces: `ClusterRepository/offsite` in namespace `kopiur-system`; secret `kopiur-offsite-secret` (keys `KOPIA_PASSWORD`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` — the operator reads only the two AWS keys; endpoint/bucket live in the ClusterRepository, so no `S3_ENDPOINT`/`S3_BUCKET` entries).
- Consumes: nothing from other phases.

### Task 1.1 — 1Password item + ExternalSecret

**Files:** Create `kubernetes/apps/kopiur-system/kopiur/repository/offsite-externalsecret.yaml`; modify `repository/kustomization.yaml`.

- [ ] **Step 1: Create the R2 bucket and a bucket-scoped token**

Cloudflare dashboard → R2 → Create bucket `kopiur-backup` (location: automatic, EU). Then R2 → Manage API tokens → Create token, permission **Object Read & Write**, scoped to `kopiur-backup` only. Record Access Key ID / Secret Access Key.

- [ ] **Step 2: Create the 1Password item**

Item `kopiur-offsite` in the vault used by the `onepassword` ClusterSecretStore, with fields:
`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Nothing else: the operator reads only these two keys from the S3 secret — endpoint and bucket live in the ClusterRepository, so `S3_ENDPOINT`/`S3_BUCKET` entries would be dead weight that only *looks* configurable.

Do **not** put a KOPIA_PASSWORD in this item, and never rotate the existing one: the seed copies the `nas` repository's already-encrypted config, so the offsite repository must use the exact same password. The ExternalSecret below therefore extracts `KOPIA_PASSWORD` from the existing `kopiur` item.

- [ ] **Step 3: Write the ExternalSecret**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/external-secrets.io/externalsecret_v1.json
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: kopiur-offsite-s3
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword
  target:
    name: kopiur-offsite-secret
  # Keyed explicitly (spec.data, not dataFrom+template) so that a stray
  # KOPIA_PASSWORD in the `kopiur-offsite` item can never shadow the one
  # from `kopiur` — the seed inherits the `nas` password verbatim and a
  # different value would break the connect after seeding.
  data:
    - secretKey: KOPIA_PASSWORD
      remoteRef:
        key: kopiur
        property: KOPIA_PASSWORD
    - secretKey: AWS_ACCESS_KEY_ID
      remoteRef:
        key: kopiur-offsite
        property: AWS_ACCESS_KEY_ID
    - secretKey: AWS_SECRET_ACCESS_KEY
      remoteRef:
        key: kopiur-offsite
        property: AWS_SECRET_ACCESS_KEY
```

- [ ] **Step 4: Register the file**

`kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml` → `resources:` add `- ./offsite-externalsecret.yaml`.

- [ ] **Step 5: Validate and commit**

```bash
mise exec -- flate test ks --path ./kubernetes/apps/kopiur-system
git add kubernetes/apps/kopiur-system/kopiur/repository/offsite-externalsecret.yaml kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml
git commit -m "feat(kopiur): add offsite repository credentials"
```

- [ ] **Step 6: Verify the Secret materialises** (after merge)

`kubectl -n kopiur-system get externalsecret kopiur-offsite-s3` → `SecretSynced=True`; `kubectl -n kopiur-system get secret kopiur-offsite-secret -o jsonpath='{.data}' | jq 'keys'` → 5 keys.

### Task 1.2 — `ClusterRepository/offsite` seeded from the NFS repository

**Files:** Create `kubernetes/apps/kopiur-system/kopiur/repository/offsite-clusterrepository.yaml`; modify `repository/kustomization.yaml`.

- [ ] **Step 1: Write the repository CR**

`create` is deliberately omitted: with `seed` present the repository content is copied from `nas`, so the operator must not re-initialise an empty one. If the repo server logs `repository already exists`, the seed already ran and the block can be removed.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kopiur.home-operations.com/clusterrepository_v1alpha1.json
apiVersion: kopiur.home-operations.com/v1alpha1
kind: ClusterRepository
metadata:
  name: offsite
spec:
  allowedNamespaces:
    all: true
  backend:
    s3:
      auth:
        secretRef:
          name: kopiur-offsite-secret
          namespace: kopiur-system
      bucket: kopiur-backup
      # bare host[:port], no scheme — kopia's S3 client (minio-go) builds the URL itself
      endpoint: d1403fac4607ccda8f0f9d8153b6c03f.eu.r2.cloudflarestorage.com
      prefix: kopiur/
      region: auto
  concurrency:
    maxConcurrentJobs: 4
  credentialProjection:
    allowed: true
  encryption:
    passwordSecretRef:
      name: kopiur-offsite-secret
      namespace: kopiur-system
      key: KOPIA_PASSWORD
  catalog:
    fallbackNamespace: kopiur-system
    periodicRefresh: true
    refreshInterval: 1h
  server:
    namespace: kopiur-system
    auth:
      generate:
        username: admin
    readOnly: false
    service:
      type: ClusterIP
      port: 51515
    podSecurityContext:
      runAsUser: 1024
      runAsGroup: 100
      fsGroup: 100
      fsGroupChangePolicy: OnRootMismatch
  identityDefaults:
    hostnameExpr: "namespace"
    usernameExpr: "namespace + '-' + policyName"
  scheduleDefaults:
    timezone: Europe/Paris
  parameters:
    epoch:
      minDuration: 2h # same as nas: the seed inherits its whole index history; slow epochs are what pile up uncompacted index blobs
  maintenance:
    enabled: true
    namespace: kopiur-system
    schedule:
      full:
        cron: "0 3 * * *"
        jitter: 1h
      quick:
        cron: "0 */6 * * *"
        jitter: 30m
      timezone: Europe/Paris
  moverDefaults:
    tolerations:
      - key: workload
        operator: Equal
        value: ai
        effect: NoSchedule
    cache:
      storageClassName: miroir-slow-local
      contentCacheSizeMb: 512
      metadataCacheSizeMb: 1024
    securityContext:
      runAsUser: 1024
      runAsGroup: 100
    podSecurityContext:
      fsGroup: 100
      fsGroupChangePolicy: OnRootMismatch
  seed:
    from:
      backend:
        filesystem:
          path: /mnt/repository
          volume:
            nfs:
              server: funkstation.internal
              path: /volume1/Volsync
```

- [ ] **Step 2: Register, validate, commit**

`repository/kustomization.yaml` → add `- ./offsite-clusterrepository.yaml`.

```bash
mise exec -- flate test ks --path ./kubernetes/apps/kopiur-system
git add kubernetes/apps/kopiur-system/kopiur/repository/offsite-clusterrepository.yaml kubernetes/apps/kopiur-system/kopiur/repository/kustomization.yaml
git commit -m "feat(kopiur): add offsite S3 repository seeded from nas"
```

- [ ] **Step 3: Watch the seed finish** (after merge)

```bash
kubectl -n kopiur-system get clusterrepository offsite -o jsonpath='{.status.conditions}'
kubectl -n kopiur-system get pods -w        # seed copier pod appears then completes
kubectl -n kopiur-system logs deploy/offsite-repository -f
```

Expected: copier completes with `0` exit, `Ready=True`. Seed is a one-time full copy of the deduplicated repo — expect hours for a multi-hundred-GiB NFS repository; it runs concurrently with normal snapshots to `nas`, which is fine.

- [ ] **Step 4: Remove the seed block**

Edit `offsite-clusterrepository.yaml` to delete the whole `seed:` block, then commit:

```bash
git commit -am "chore(kopiur): drop offsite repository seed"
```

- [ ] **Step 5: Confirm the repository is readable**

```bash
kubectl -n kopiur-system port-forward svc/offsite-repository 51515:51515
# browser: http://localhost:51515 → log in with the generated admin credentials
#            (kubectl -n kopiur-system get secret offsite-repository-auth -o jsonpath='{.data}')
```

Expected: the identity list matches `nas` (`<namespace>-<app>` identities, e.g. `media-plex`, `self-hosted-forgejo`), snapshot counts per identity match.

### Task 1.3 — Promote `offsite` to the component default

**Files:** Modify `kubernetes/components/kopiur/backup/snapshotpolicy.yaml`; modify `kubernetes/components/kopiur/README.md`.

- [ ] **Step 1: Flip the default**

```yaml
  repository:
    kind: ClusterRepository
    name: ${KOPIUR_REPOSITORY:=offsite}
```

- [ ] **Step 2: Update the README**

In the substitution table, change `KOPIUR_REPOSITORY` default to `offsite`; add a design note: "Primary repository is the offsite S3 `offsite` (R2); the NFS `nas` repository is a frozen `ReadOnly` archive kept for fast local restores and as a seed source. Apps that must not leave the LAN set `KOPIUR_REPOSITORY: nas` in their `postBuild.substitute` and accept that the archive is read-only."

- [ ] **Step 3: Validate and commit**

```bash
mise exec -- flate test hr --path ./kubernetes/apps
git commit -am "feat(kopiur): default SnapshotPolicy to the offsite repository"
```

- [ ] **Step 4: Verify one full cycle across a sample of apps**

```bash
kubectl get snapshotpolicy -A
kubectl get snapshot -A --sort-by=.metadata.creationTimestamp | tail -30
kubectl -n media get snapshot -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Complete")].status}{"\n"}{end}'
```

Expected: newest snapshots reference repository `offsite`; conditions `Complete=True`. Check three namespaces with different mover identities (e.g. `media/plex`, `self-hosted/forgejo`, `ai/opencode` or `ai/memini`) — those are the ones that would break if UID handling regressed.

- [ ] **Step 5: Sanity-check volume growth**

`kubectl -n kopiur-system port-forward svc/offsite-repository 51515` → repository size; compare with the R2 bucket usage in the Cloudflare dashboard. Expect ≈ the same deduplicated size, plus the new hour of incrementals.

### Task 1.4 — Freeze the NFS repository

**Files:** Modify `kubernetes/apps/kopiur-system/kopiur/repository/clusterrepository.yaml`.

- [ ] **Step 1: Make it a read-only weekly-maintained archive**

```yaml
  mode: ReadOnly
  parameters:
    epoch:
      minDuration: 2h
  maintenance:
    enabled: true
    namespace: kopiur-system
    schedule:
      full:
        cron: "0 3 * * 0"
        jitter: 1h
      quick:
        cron: "0 */6 * * *"
        jitter: 30m
      timezone: Europe/Paris
  bootstrap:
    failurePolicy:
      activeDeadlineSeconds: 3600
```

Keep `create.enabled: false` and `server.readOnly: false` untouched (the latter is about the *kopia web UI*, not the repository mode).

- [ ] **Step 2: Commit**

```bash
git commit -am "feat(kopiur): freeze the NFS repository as a read-only archive"
```

- [ ] **Step 3: Verify no writes are attempted**

```bash
kubectl -n kopiur-system get clusterrepository nas -o jsonpath='{.spec.mode}'
kubectl -n kopiur-system logs deploy/nas-repository --tail=50 | grep -i "read.only\|readonly\|denied"
kubectl get snapshot -A --sort-by=.metadata.creationTimestamp | tail -5   # must all reference offsite
```

If any app fails with a write-denied error, it still has `KOPIUR_REPOSITORY: nas` in its `postBuild.substitute`; find them with `grep -rn "KOPIUR_REPOSITORY" kubernetes/apps`.

### Task 1.5 — Restore drill (non-destructive)

- [ ] **Step 1: File-level restore from `offsite`**

Port-forward `svc/offsite-repository` (as in Task 1.2 Step 5), pick a small app identity (e.g. `automation-teslamate`), browse a snapshot, restore a single file to the browser. Expected: download succeeds, proving credentials, encryption password, and object integrity.

- [ ] **Step 2: Record the drill in the repo**

Append to `kubernetes/components/kopiur/README.md` under a `## Restore drill` heading: date, repository (`offsite`), identity used, and the fact that a full PVC drill is pending.

- [ ] **Step 3: Full PVC drill (follow-up PR, do not improvise)**

Plan it explicitly: create a scratch namespace, add the `kopiur/backup` component with the **same** `APP` name as the app being restored so the pinned `identity.username: ${APP}` matches, patch its `SnapshotSchedule` with `spec.suspend: true` (otherwise the scratch policy starts writing snapshots under the live identity), and let `Restore` populate the PVC. Delete the namespace afterwards. Do not run this against an app whose identity has a running mover.

**Phase 1 rollback:** revert the `KOPIUR_REPOSITORY` default commit and set `nas` back to `mode: ReadWrite`; `offsite` can stay in place harmlessly (nothing writes to it once policies point back at `nas`).

---

## Phase 2 — Talos system logs into VictoriaLogs

**Deliverable:** etcd, kubelet, containerd and syslogd output from all 4 nodes is queryable in VictoriaLogs with a `node` and `talos-service` stream field. Pod logs already ship (`victoria-logs-collector`) and are out of scope.

**Files:**
- Create: `kubernetes/apps/observability/fluent-bit/ks.yaml`
- Create: `kubernetes/apps/observability/fluent-bit/app/kustomization.yaml`
- Create: `kubernetes/apps/observability/fluent-bit/app/ocirepository.yaml`
- Create: `kubernetes/apps/observability/fluent-bit/app/helmrelease.yaml`
- Modify: `kubernetes/apps/observability/kustomization.yaml`
- Modify: `kubernetes/apps/observability/victoria-logs/app/helmrelease.yaml` (PV 20Gi → 30Gi)
- Modify: `talos/main/cluster.yaml.j2`

**Interfaces:**
- Produces: `ServiceAccount`-less DaemonSet `observability/fluent-bit` listening on `127.0.0.1:5171/tcp` on every node (hostNetwork), shipping tag `talos.service` to `http://victoria-logs.observability.svc.cluster.local:9428/insert/jsonline`.
- Consumes: VictoriaLogs server already running (Phase 0 baseline).

### Task 2.1 — fluent-bit DaemonSet (Talos service logs only)

- [ ] **Step 1: OCIRepository**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: fluent-bit
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.58.3
  url: oci://ghcr.io/fluent/helm-charts/fluent-bit
```

- [ ] **Step 2: HelmRelease**

`hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` is mandatory: Talos writes to `127.0.0.1:5171`, which is only reachable from the host network namespace.

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: fluent-bit
spec:
  chartRef:
    kind: OCIRepository
    name: fluent-bit
  interval: 1h
  values:
    kind: DaemonSet
    hostNetwork: true
    dnsPolicy: ClusterFirstWithHostNet
    env:
      - name: NODE_NAME
        valueFrom:
          fieldRef:
            fieldPath: spec.nodeName
    config:
      service: |-
        [SERVICE]
          daemon off
          flush {{ .Values.flush }}
          log_level {{ .Values.logLevel }}
          parsers_file /fluent-bit/etc/parsers.conf
          parsers_file /fluent-bit/etc/conf/custom_parsers.conf
          http_server on
          http_listen 0.0.0.0
          http_port {{ .Values.metricsPort }}
          health_check on
      inputs: |-
        [INPUT]
          name tcp
          alias talos_service
          listen 127.0.0.1
          port 5171
          tag talos.service
          format json
          chunk_size 64
          buffer_size 256
      filters: |-
        # dns-resolve-cache logs every host DNS query; kernel lines arrive via KmsgLogConfig once that exists
        [FILTER]
          name grep
          match talos.service
          exclude $talos-service ^(kernel|dns-resolve-cache)$
        [FILTER]
          name modify
          match talos.*
          add node ${NODE_NAME}
          rename talos-level level
          rename talos-time talos_time
      outputs: |-
        # syslogd puts its message in content, not msg
        [OUTPUT]
          name http
          match talos.service
          host victoria-logs-server.observability.svc.cluster.local
          port 9428
          uri /insert/jsonline?_stream_fields=node,talos-service&_msg_field=msg,content&_time_field=talos_time
          format json_lines
          json_date_key false
          compress gzip
          log_response_payload false
    dashboards:
      enabled: true
    serviceMonitor:
      enabled: true
    logLevel: warn
```

- [ ] **Step 3: kustomization + Flux Kustomization**

`app/kustomization.yaml`:

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: observability
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
```

`ks.yaml` (same shape as `victoria-logs/ks.yaml`, no extra dependency needed):

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: fluent-bit
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: fluent-bit
  interval: 1h
  path: ./kubernetes/apps/observability/fluent-bit/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: observability
  wait: false
```

- [ ] **Step 4: Register in `observability/kustomization.yaml`**

Add `- ./fluent-bit/ks.yaml` after `- ./blackbox-exporter/ks.yaml` (alphabetical).

- [ ] **Step 5: Validate and commit**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/observability
git add kubernetes/apps/observability/fluent-bit kubernetes/apps/observability/kustomization.yaml
git commit -m "feat(observability): add fluent-bit for Talos system logs"
```

- [ ] **Step 6: Verify the listener exists on every node** (after merge)

```bash
kubectl -n observability get ds fluent-bit -o wide      # DESIRED 4, READY 4
kubectl -n observability logs ds/fluent-bit --tail=20    # "TCP server listening on 127.0.0.1:5171"
```

Nothing arrives yet — Talos does not send anything until Task 2.3.

### Task 2.2 — Give VictoriaLogs headroom

- [ ] **Step 1: Bump the volume**

`kubernetes/apps/observability/victoria-logs/app/helmrelease.yaml`: `server.persistentVolume.size: 20Gi` → `30Gi`. Verify the StorageClass allows expansion first:

```bash
kubectl get sc miroir-slow -o jsonpath='{.allowVolumeExpansion}'
```

Expected `true`. If `false`, keep 20Gi and instead lower `server.retentionPeriod` to `7d` — the two options are not interchangeable, pick one and note it in the commit body.

- [ ] **Step 2: Commit and verify the PVC grew**

```bash
git commit -am "feat(observability): grow VictoriaLogs volume for system logs"
kubectl -n observability get pvc -l app.kubernetes.io/name=victoria-logs
```

### Task 2.3 — Ship Talos service logs

**Files:** Modify `talos/main/cluster.yaml.j2`.

- [ ] **Step 1: Add the logging block**

Inside the existing top-level `machine:` mapping (same file; keep alphabetical-ish placement near `kubelet:`/`network:`):

```yaml
  logging:
    destinations:
      - endpoint: tcp://127.0.0.1:5171/
        format: json_lines
```

- [ ] **Step 2: Render and inspect before touching nodes**

```bash
just talos render-config k8s-0 | yq '.machine.logging'
```

Expected: the destination block, no other diff. Also confirm the field is accepted by the installed Talos version:

```bash
just talos render-config k8s-0 | talosctl validate --config - --mode metal
```

- [ ] **Step 3: Apply, one node at a time**

```bash
just talos apply-node k8s-3    # GPU worker first: no etcd impact
just talos apply-node k8s-0    # then control plane, one at a time, waiting for Ready between each
just talos apply-node k8s-1
just talos apply-node k8s-2
```

Between control-plane nodes:

```bash
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=kube-apiserver -o wide
```

- [ ] **Step 4: Verify ingestion**

```bash
kubectl -n observability port-forward svc/victoria-logs-server 9428:9428
curl -s 'http://127.0.0.1:9428/select/logsql/query' \
  --data-urlencode 'query=talos-service:etcd' --data-urlencode 'limit=5'
curl -s 'http://127.0.0.1:9428/select/logsql/query' \
  --data-urlencode 'query=talos-service:kubelet | stats by (node) count()' 
```

Expected: etcd lines present, and one row per node (4 nodes) in the kubelet count. Check Grafana → Explore → VictoriaLogs for the same queries.

- [ ] **Step 5: Optional — kernel/kmsg logs**

Only if kernel messages are wanted, add a Talos `KmsgLogConfig` document with a second fluent-bit input on port 5170 (`format json`, tag `talos.kernel`) and the matching HTTP output using `_stream_fields=node,facility,priority,level&_msg_field=msg&_time_field=date`. Validate with `talosctl validate` before applying; keep it in its own PR.

**Phase 2 rollback:** remove the `machine.logging` block and re-apply to each node (Talos stops shipping immediately, nothing else changes); the fluent-bit HelmRelease can stay or be deleted without data loss.

---

## Phase 3 — Tracing backend (VictoriaTraces)

**Deliverable:** a Grafana datasource named `VT` (Jaeger-compatible) against a single-node VictoriaTraces with 3-day retention; nothing is instrumented yet.

**Files:**
- Create: `kubernetes/apps/observability/victoria-traces/ks.yaml`
- Create: `kubernetes/apps/observability/victoria-traces/app/kustomization.yaml`
- Create: `kubernetes/apps/observability/victoria-traces/app/ocirepository.yaml`
- Create: `kubernetes/apps/observability/victoria-traces/app/helmrelease.yaml`
- Create: `kubernetes/apps/observability/victoria-traces/app/grafanadatasource.yaml`
- Modify: `kubernetes/apps/observability/kustomization.yaml`

**Interfaces:** Produces `svc/victoria-traces-server.observability:10428` with `/select/jaeger` and `/insert/opentelemetry/v1/traces`.

- [ ] **Step 1: OCIRepository**

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: victoria-traces
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 0.1.13
  url: oci://ghcr.io/victoriametrics/helm-charts/victoria-traces-single
```

- [ ] **Step 2: HelmRelease** (local storage: traces are short-lived, no need to replicate)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/helm.toolkit.fluxcd.io/helmrelease_v2.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: victoria-traces
spec:
  chartRef:
    kind: OCIRepository
    name: victoria-traces
  interval: 1h
  values:
    fullnameOverride: victoria-traces
    server:
      persistentVolume:
        enabled: true
        storageClassName: miroir-slow-local
        size: 10Gi
      retentionPeriod: 3d
      serviceMonitor:
        enabled: true
```

- [ ] **Step 3: Grafana datasource** (note the project's `instanceSelector` label)

```yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/grafana.integreatly.org/grafanadatasource_v1beta1.json
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: vt-datasource
spec:
  instanceSelector:
    matchLabels:
      grafana.internal/instance: grafana
  datasource:
    access: proxy
    type: jaeger
    name: VT
    url: http://victoria-traces-server.observability.svc.cluster.local:10428/select/jaeger
```

- [ ] **Step 4: kustomization + ks.yaml + register**

`app/kustomization.yaml` lists the four files above (`namespace: observability`); `ks.yaml` follows the `victoria-logs/ks.yaml` shape (name `victoria-traces`, path `./kubernetes/apps/observability/victoria-traces/app`, `targetNamespace: observability`); add `- ./victoria-traces/ks.yaml` to `observability/kustomization.yaml`.

- [ ] **Step 5: Validate, commit, verify**

```bash
mise exec -- flate test hr --path ./kubernetes/apps/observability
git add kubernetes/apps/observability/victoria-traces kubernetes/apps/observability/kustomization.yaml
git commit -m "feat(observability): add single-node VictoriaTraces and Grafana datasource"
kubectl -n observability get hr victoria-traces
kubectl -n observability get grafanadatasource vt-datasource
```

Expected: HR `Ready=True`, datasource `STATUS=OK`, and Grafana → Connections → Data sources shows `VT` passing its health check (an empty trace store still answers).

- [ ] **Step 5b: Instrument later, in its own PR**

Pick one app (litellm is the natural first candidate: it is the busiest and already talks to an external gateway), deploy an OpenTelemetry Collector (or set the app's native OTLP exporter to `http://victoria-traces-server.observability:10428/insert/opentelemetry/v1/traces`), and confirm traces appear in Grafana Explore before touching a second app.

**Phase 3 rollback:** delete `victoria-traces/ks.yaml` + its kustomization entry; the datasource CR goes with the ks (prune). Grafana simply loses the `VT` entry.

---

## Phase 4 — BGP failover timers

**Deliverable:** VIP failover on node loss drops from ~90 s (hold time) to ~15 s, and session teardown is detected in ~15 s instead of ~90 s.

**Files:** Modify `kubernetes/apps/kube-system/cilium/app/networking.yaml`.

**Interfaces:** none — consumes the existing `CiliumBGPPeerConfig l3-bgp-peer-config` / peer `unifi` (64514 → 64513).

- [ ] **Step 1: Capture the pre-change baseline**

```bash
kubectl -n kube-system exec ds/cilium -- cilium bgp peers
kubectl get ciliumbgppeerconfig l3-bgp-peer-config -o yaml | grep -A5 timers
```

Record uptime per peer — you will compare it after the change.

- [ ] **Step 2: Add the timers block**

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: l3-bgp-peer-config
spec:
  timers:
    holdTimeSeconds: 15
    keepAliveTimeSeconds: 5
    connectRetryTimeSeconds: 120
  families:
    - afi: ipv4
      safi: unicast
      advertisements:
        matchLabels:
          advertise: bgp
```

Keep the `families` block byte-for-byte as it is today; only `timers` is added.

- [ ] **Step 3: Validate and commit**

```bash
mise exec -- flate test ks --path ./kubernetes/apps/kube-system
git commit -am "feat(network): tighten cilium BGP hold and keepalive timers"
```

- [ ] **Step 4: Verify sessions re-establish and stay up**

```bash
kubectl -n kube-system exec ds/cilium -- cilium bgp peers
```

Expected: `hold time: 15s`, `keepalive: 5s`, state `established` on all 4 nodes. Then watch for 24 h:

```bash
kubectl -n kube-system exec ds/cilium -- cilium bgp peers | grep -v established
```

Any flap is a signal the UniFi side (or the path) cannot sustain 5 s keepalives — revert, don't tune upward incrementally.

- [ ] **Step 5: Prove the failover improvement (optional but recommended)**

Drain or reboot `k8s-3` and time how long an internal VIP (`envoy-internal`, 10.10.98.251) keeps answering:

```bash
while true; do date +%T; curl -sk -o /dev/null -w '%{http_code}\n' --max-time 1 https://10.10.98.251; sleep 1; done
```

Record the gap in the commit/PR description.

- [ ] **Step 6: Optional — kanidm COOP header (only if symptoms exist)**

If OIDC popups/redirects misbehave (Kanidm login in an iframe, or WebAuthn prompts), add to the Kanidm `HTTPRoute` in `kubernetes/apps/security/kanidm/app/helmrelease.yaml`, on the `/ui/oauth2`, `/ui/login`, `/ui/reset` paths:

```yaml
            filters:
              - type: ResponseHeaderModifier
                responseHeaderModifier:
                  remove:
                    - Cross-Origin-Opener-Policy
```

Do not do this speculatively: removing COOP weakens cross-origin isolation.

**Phase 4 rollback:** delete the `timers:` block; Cilium returns to 90 s/30 s on the next reconcile.

---

## Out of scope (deliberately not planned)

| Candidate | Why not |
|---|---|
| Convert ~43 single-replica apps to `StatefulSet` | The audit's real win (`podManagementPolicy: Parallel`) is quick win #4; the mass type change adds `CONTROLLER: StatefulSet` substitutions everywhere for no behavioural gain on top of that. Revisit only if a rollout is observably blocked by a PVC. |
| UniFi-as-code (Pulumi) | Weeks of work, no incident it prevents today; the cluster side (external-dns → UniFi, unpoller) is already declarative. |
| `hubble` metrics/dashboard retune | Already equivalent in `kube-system/cilium`. |
| Remove `bpf.preallocateMaps: true` | Memory-only trade-off; no observed pressure, and re-enabling later is a restart. Measure first. |
| Dragonfly RDB snapshots | Cache, 2 replicas, rebuildable — snapshotting it buys nothing. |
| CNPG per-cluster PDB / `enablePDB: false` | Upstream recommends keeping PDBs; radar's `pdb_blocks_evictions` is a known false positive (see `AGENTS.md`). |

## Self-review checklist (run before opening each PR)

1. Every phase's files exist and `metadata.namespace` is absent from HR/KS.
2. `flate test ks` + `flate test hr` clean for the touched paths.
3. No new plaintext secret; new ExternalSecrets reference an existing item name.
4. No `kubectl` mutation of Flux-managed objects in the process (verification is read-only).
5. Rollback path documented in the PR body (copy from the phase section above).
