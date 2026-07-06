set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l talos

[confirm('Apply Talos config to ' + node + ' [y|N] ?')]
[doc('Apply Talos config to a node (use target to override the talosctl endpoint, e.g. on first join via IP)')]
apply-node node target=node *args:
    just talos render-config "{{ node }}" | talosctl -n "{{ target }}" apply-config -f /dev/stdin {{ args }}

[doc('Download Talos machine image (ISO factory) for a node')]
[script]
download-image node version:
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    curl -fL --remove-on-error --retry 5 --retry-delay 5 --retry-all-errors --progress-bar \
        -o "{{ source_directory() }}/talos-{{ node }}-{{ version }}-${SCHEMATIC:0:8}.iso" \
        "https://factory.talos.dev/image/${SCHEMATIC}/{{ version }}/metal-amd64.iso"
    just log info "Downloaded Talos" version "{{ version }}" schematic "${SCHEMATIC}" node "{{ node }}"

[confirm('Reboot node ' + node + ' [y|N] ?')]
[doc('Reboot a node')]
reboot-node node:
    talosctl -n {{ node }} reboot -m powercycle

[doc('Render Talos config for a node (machine type inferred from the subdirectory containing <node>.yaml)')]
[script]
render-config node:
    export MACHINE_TYPE="$(just talos machine-type {{ node }})"
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    PATCH_ARGS=()
    TYPE_PATCH="{{ source_directory() }}/main/${MACHINE_TYPE}/${MACHINE_TYPE}.yaml"
    if [ -f "${TYPE_PATCH}" ]; then
        PATCH_ARGS+=(-p @"${TYPE_PATCH}")
    fi
    talosctl machineconfig patch <(just template "{{ source_directory() }}/main/machineconfig.yaml.j2") \
        "${PATCH_ARGS[@]}" \
        -p @<(just template "{{ source_directory() }}/main/${MACHINE_TYPE}/{{ node }}.yaml")

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe u-local-hostpath --graceful=false {{ args }}

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown a node')]
shutdown-node node *args:
    talosctl -n "{{ node }}" shutdown --force {{ args }}

[confirm('Upgrade Kubernetes to ' + version + ' [y|N] ?')]
[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "$(talosctl config info -o yaml | yq -e '.endpoints[0]')" upgrade-k8s --to {{ version }}

[confirm('Upgrade node ' + node + ' [y|N] ?')]
[doc('Upgrade Talos version on a node')]
upgrade-node node *args:
    talosctl -n "{{ node }}" upgrade -i "$(just talos machine-image {{ node }})" -m powercycle --timeout=10m {{ args }}

[private]
[script]
schematic-id node:
    #!/usr/bin/env bash
    set -euo pipefail
    MACHINE_TYPE="$(just talos machine-type {{ node }})"
    SCHEMATIC_FILE="{{ source_directory() }}/main/${MACHINE_TYPE}/schematic.yaml"
    just template "${SCHEMATIC_FILE}" | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" | jq -r '.id'

[private]
[script]
machine-type node:
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_FILE="$(find "{{ source_directory() }}/main" -name "{{ node }}.yaml" -print -quit)"
    if [ -z "${NODE_FILE}" ]; then
        echo "error: no patch file found for node '{{ node }}' under {{ source_directory() }}/main/{controlplane,worker}/" >&2
        exit 1
    fi
    basename "$(dirname "${NODE_FILE}")"

[private]
[script]
machine-image node:
    #!/usr/bin/env bash
    set -euo pipefail
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    just template "{{ source_directory() }}/main/machineconfig.yaml.j2" | yq -e 'select(.machine) | .machine.install.image'