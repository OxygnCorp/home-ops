# Talos

Declarative [Talos Linux](https://www.talos.dev) machine configuration for the cluster, built from a shared template plus layered patches. Nothing in this directory is applied automatically; configs are rendered on demand and pushed to nodes with `talosctl` (the `nodes` stage of `just bootstrap cluster` does the initial push).

## Layout

| Path                                   | Purpose                                                              |
|----------------------------------------|----------------------------------------------------------------------|
| `main/machineconfig.yaml.j2`           | Base documents applied to every node (Jinja + `vals` templated)      |
| `main/controlplane/controlplane.yaml`  | Control-plane-only patch (zone label for hyper-converged placement)  |
| `main/controlplane/<node>.yaml`        | Per-node documents for control-plane nodes (hostname, NICs, routes)  |
| `main/controlplane/schematic.yaml`     | [Image Factory](https://factory.talos.dev) schematic for control-plane |
| `main/worker/worker.yaml`              | Worker-only patch (placeholder — per-node patches own everything)    |
| `main/worker/<node>.yaml`              | Per-node documents for worker nodes                                  |
| `main/worker/schematic.yaml`           | Image Factory schematic for workers                                  |
| `mod.just`                             | Recipes (`just talos ...`)                                           |

## Nodes

| Node     | Role          | Notes                                                                                                     |
|----------|---------------|-----------------------------------------------------------------------------------------------------------|
| `k8s-0`  | control-plane | bond0 active-backup MTU 9000; dedicated link-local `net1` links used for DRBD replication between CP nodes |
| `k8s-1`  | control-plane | idem                                                                                                      |
| `k8s-2`  | control-plane | idem                                                                                                      |
| `k8s-3`  | worker        | GPU node (NVIDIA), MTU 1500, tainted `workload=ai:NoSchedule`                                             |

All nodes run on Proxmox VE VMs and share `topology.kubernetes.io/zone: m` (co-located on the same host).

## Rendering

`just talos render-config <node>` builds the final machine config in three layers:

```text
talosctl machineconfig patch <(machineconfig.yaml.j2) \
    -p @<main/<role>/<role>.yaml \
    -p @<main/<role>/<node>.yaml
```

The base template and the per-node patch pass through `just template` — i.e. `minijinja-cli` (strict Jinja; `ENV.MACHINE_TYPE` and `ENV.SCHEMATIC` are provided) followed by `vals eval` (resolves `ref+op://home-ops/talos/*` against 1Password) — before `talosctl` merges them; the role patch is merged as-is. Later patches strategic-merge into earlier ones: documents with the same kind/name are deep-merged, new documents are appended.

Two conventions keep the layers honest:

- **Directory placement is the single source of truth for a node's role.** The role is inferred from which `main/<role>/` directory contains `<node>.yaml`, and `machine.type` is set in the base template from that role — a node cannot claim one role by filename and another by content.
- **Secrets never live in this repo.** All sensitive values (CAs, tokens, cluster secret) are `ref+op://home-ops/talos/...` references resolved at render time by `vals`.

Versions are pinned in the base template: Talos `v1.14.0` installer image and kubelet / control-plane component images `v1.37.0`.

## Schematics

The schematic defines the Image Factory build (system extensions, kernel args) and is **per role**:

- `controlplane/schematic.yaml`: `qemu-guest-agent` (Proxmox), `drbd` (Miroir replication), PCI passthrough kernel args (`intel_iommu=on iommu=pt`)
- `worker/schematic.yaml`: NVIDIA kernel modules (`nonfree-kmod-nvidia-lts`) + container toolkit, `intel-ucode`, same IOMMU args

`just talos schematic-id <node>` POSTs the role's schematic to the factory and returns a content-addressed ID, which is templated into the installer image reference and used by `download-image` and `upgrade-node`. There are no per-node schematic overrides — a diverging node would get its own `schematic.yaml` next to its patch.

## Gotchas

- **CA blocks merge as cert+key units.** `machine.ca`, `cluster.ca` and `etcd.ca` merge as a cert+key **unit**: a patch supplying only `key` blanks `crt`. This is why the base template guards the `key` references with `{% if ENV.MACHINE_TYPE == "controlplane" %}` instead of carrying them in the role patch.
- **Worker taints must be registered, not applied.** `machine.nodeTaints` is rejected on workers by the `NodeRestriction` admission plugin (the NodeApplyController's `Nodes().Update()` is forbidden). `k8s-3.yaml` therefore sets the `workload=ai:NoSchedule` taint via the kubelet's `register-with-taints` extraArg, which is only consulted at Node object creation and is automatically re-applied on rejoin/reset.
- **Install disk is `/dev/sdb` while booted from the USB ISO.** The installer image occupies `/dev/sda` in maintenance mode; once Talos is installed on the SSD and the stick removed, the disk reverts to `/dev/sda` at the next boot — harmless, Talos already flashed and boots from it. On `k8s-3`, `wipe: true` guarantees a clean partition table (destructive: wipes the target disk).
- **Adding a node means adding a patch file.** Rendering fails loudly if no `main/<role>/<node>.yaml` exists; create the file in the directory matching the intended role.

## Common tasks

```sh
just talos render-config <node>         # render a node's full machine config to stdout
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
