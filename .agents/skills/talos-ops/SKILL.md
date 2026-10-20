---
name: talos-ops
description: Use when operating Talos nodes or editing machine configs — before running any talosctl command or just talos recipe (apply-node, reset-node, upgrade-node, reboot-node, shutdown-node, render-config, schematic-id, download-image, upgrade-k8s), or when touching anything under talos/
---

# Talos Operations

Read `talos/README.md` first. It is the source of truth for this directory: 3-layer rendering (`cluster.yaml.j2` → role patch (`controlplane.yaml.j2`/`workers.yaml.j2`) → per-node patch (`nodes/<role>/<node>.yaml.j2`), minijinja + vals), per-role Image Factory schematics, and gotchas that are easy to get wrong (CA `crt`/`key` unit merge, worker taints vs NodeRestriction, `/dev/sdb` USB-ISO disk renumbering).

## Non-negotiables

1. **Edit the layered sources, never rendered output.** Per-node changes go in `talos/main/nodes/<role>/<node>.yaml.j2`; cluster-wide changes in `talos/main/cluster.yaml.j2`. Then apply with `just talos apply-node <node>`.
2. **Verify before and after.** Preview with `just talos apply-node <node> --dry-run` (expect `No changes.` when already in sync). For a per-node change, confirm isolation: the new key must appear in the target's `just talos render-config <node>` and in no sibling's output.
3. **Respect the confirmation prompts.** `reset-node` wipes STATE/EPHEMERAL, `reboot-node`/`shutdown-node`/`upgrade-node` take the node down — verify the target node name before confirming.
4. **Secrets are `ref+op://home-ops/talos/*` references** resolved at render time by vals. Never commit resolved values, never add plain-text secrets.
5. **Role = directory.** A node's machine type is inferred from which `main/nodes/{controlplane,workers}/` directory holds its `<node>.yaml.j2`. Adding a node means creating that patch file in the role directory; rendering fails loudly without it (an all-comments placeholder renders empty and its layer is skipped).

## Version upgrades (GitOps path)

Cluster upgrades are driven by tuppr, not by hand:

- Kubernetes: `kubernetes/apps/system-upgrade/tuppr/upgrades/kubernetesupgrade.yaml` (Renovate bumps `version`; tuppr rolls nodes with kopiur Snapshot/Restore health checks)
- Talos: `kubernetes/apps/system-upgrade/tuppr/upgrades/talosupgrade.yaml`

If you bump the Kubernetes version, two places must move together: the `version` in `kubernetesupgrade.yaml` and the **5 component image pins** — kubelet in `talos/main/cluster.yaml.j2`, apiserver/controller-manager/proxy/scheduler in `talos/main/controlplane.yaml.j2`. The Talos installer version is a *separate* axis — governed by `talosupgrade.yaml`, and pinned in **two** files (`cluster.yaml.j2` `nocloud-installer` and `nodes/workers/k8s-3.yaml.j2` `metal-installer`); never couple it to a Kubernetes bump. `just talos upgrade-k8s <version>` / `just talos upgrade-node <node>` are manual fallbacks only — prefer the GitOps path so state doesn't drift.
