# Talos

Declarative [Talos Linux](https://www.talos.dev) machine configuration for the cluster, built from a shared template plus layered patches. Nothing in this directory is applied automatically; configs are rendered on demand and pushed to nodes with `talosctl` (the `nodes` stage of `just bootstrap cluster` does the initial push).

## Layout

| Path                                   | Purpose                                                              |
|----------------------------------------|----------------------------------------------------------------------|
| `main/cluster.yaml.j2`                 | Base documents applied to every node (role-agnostic; Jinja + `vals`) |
| `main/controlplane.yaml.j2`            | Control-plane-only patch (type, CA cert+key pairs, zone label, CP docs) |
| `main/workers.yaml.j2`                 | Worker-only patch (type — per-node patches own everything else)      |
| `main/nodes/controlplane/<node>.yaml.j2` | Per-node documents for control-plane nodes (hostname, NICs, routes)|
| `main/nodes/workers/<node>.yaml.j2`    | Per-node documents for worker nodes (k8s-3: GPU, metal installer, LACP) |
| `main/controlplane/schematic.yaml`     | [Image Factory](https://factory.talos.dev) schematic for control-plane |
| `main/worker/schematic.yaml`           | Image Factory schematic for workers                                  |
| `mod.just`                             | Recipes (`just talos ...`)                                           |

## Nodes

| Node     | Role          | Notes                                                                                                     |
|----------|---------------|-----------------------------------------------------------------------------------------------------------|
| `k8s-0`  | control-plane | bond0 active-backup MTU 9000; dedicated link-local `net1` links used for DRBD replication between CP nodes |
| `k8s-1`  | control-plane | idem                                                                                                      |
| `k8s-2`  | control-plane | idem                                                                                                      |
| `k8s-3`  | worker        | GPU node (NVIDIA), bond0 LACP MTU 9000, tainted `workload=ai:NoSchedule`                                             |

All nodes run on Proxmox VE VMs and share `topology.kubernetes.io/zone: m` (co-located on the same host).

## Rendering

`just talos render-config <node>` builds the final machine config in three layers:

```text
talosctl machineconfig patch <(cluster.yaml.j2) \
    -p @<{controlplane,workers}.yaml.j2 \
    -p @<nodes/<role>/<node>.yaml.j2      # optional — empty render = skipped
```

All three layers pass through `just template` — i.e. `minijinja-cli` (strict Jinja; `ENV.SCHEMATIC` is provided) followed by `vals eval`, which expands `ref+envsubst://$FIELD` references from the environment (fields of the single `talos` 1Password item, fetched once per secrets TTL window and cached in tmpfs — no per-ref API resolution at render time) — before `talosctl` merges them. Later patches strategic-merge into earlier ones: documents with the same kind/name are deep-merged, new documents are appended, **lists are appended** (never redefine a list across layers).

The composed result is guarded (type per role, CP docs present, no duplicate list entries) and cached: unchanged inputs skip both the 1Password fetch and the re-render.

Two conventions keep the layers honest:

- **Directory placement is the single source of truth for a node's role.** The role is inferred from which `nodes/` subdirectory contains `<node>.yaml.j2`, and `machine.type` is set by the role layer — a node cannot claim one role by filename and another by content.
- **Secrets never live in this repo.** All sensitive values (CAs, tokens, cluster secret) live in the single `talos` 1Password item, fetched once per secrets TTL window by `just talos secrets-env` (cached at `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache/secrets.env`, `TALOS_SECRETS_TTL` seconds — default 3600) and expanded by `vals` via `ref+envsubst://` at render time.

Versions are pinned in the layer templates: Talos `v1.14.4` installer image and kubelet image `v1.37.1` in `cluster.yaml.j2`; the four control-plane component images `v1.37.1` in `controlplane.yaml.j2`.

## Schematics

The schematic defines the Image Factory build (system extensions, kernel args) and is **per role**:

- `controlplane/schematic.yaml`: `qemu-guest-agent` (Proxmox), `drbd` (Miroir replication), PCI passthrough kernel args (`intel_iommu=on iommu=pt`)
- `worker/schematic.yaml`: NVIDIA kernel modules (`nonfree-kmod-nvidia-lts`) + container toolkit, `intel-ucode`, same IOMMU args

`just talos schematic-id <node>` POSTs the role's schematic to the factory and returns a content-addressed ID, templated into the installer image reference and used by `download-image`, `machine-image` and `upgrade-node`. Per-node schematic overrides are supported: `nodes/*/<node>.schematic.yaml.j2` wins over the role schematic when present (none today).

## Gotchas

- **CA blocks merge cert+key as a unit.** `machine.ca`, `cluster.ca` and `etcd.ca` merge cert+key as **a unit**: a patch supplying only `key` blanks `crt`. This is why the control-plane role patch always carries the full `crt`+`key` pair (repeated from the base), never the key alone.
- **Worker taints must be registered, not applied.** `machine.nodeTaints` is rejected on workers by the `NodeRestriction` admission plugin (the NodeApplyController's `Nodes().Update()` is forbidden). `k8s-3.yaml.j2` therefore sets the `workload=ai:NoSchedule` taint via the kubelet's `register-with-taints` extraArg, which is only consulted at Node object creation and is automatically re-applied on rejoin/reset.
- **Install disk is `/dev/sdb` while booted from the USB ISO.** The installer image occupies `/dev/sda` in maintenance mode; once Talos is installed on the SSD and the stick removed, the disk reverts to `/dev/sda` at the next boot — harmless, Talos already flashed and boots from it. On `k8s-3`, `wipe: true` guarantees a clean partition table (destructive: wipes the target disk).
- **Adding a node means adding a patch file.** Rendering fails loudly if no `nodes/<role>/<node>.yaml.j2` exists; create the file in the directory matching the intended role (an all-comments placeholder renders empty and the layer is skipped).

## Common tasks

```sh
just talos render-config <node>         # render a node's full machine config to stdout
just talos diff-config <node>       # semantic diff: rendered vs live config
just talos flush-cache                  # drop rendered-config + secrets caches (tmpfs)
just talos apply-node <node>            # render and apply (talosctl apply-config)
just talos upgrade-node <node>          # upgrade Talos using the node's schematic image
just talos upgrade-k8s <version>        # upgrade Kubernetes across the cluster
just talos download-image <node> <version>  # fetch a metal ISO from the Image Factory
just talos reboot-node <node>           # powercycle reboot
just talos reset-node <node>            # ⚠️ wipes STATE/EPHEMERAL — destructive
```

Verify a refactor of these templates by diffing rendered output before and after, then confirming the live config matches:

```sh
just talos apply-node <node> --dry-run   # expect "No changes." when in sync
```
