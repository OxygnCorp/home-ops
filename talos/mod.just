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
    #!/usr/bin/env bash
    set -euo pipefail
    export MACHINE_TYPE="$(just talos machine-type {{ node }})"
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    MAIN="{{ source_directory() }}/main"
    CACHE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache"
    mkdir -p "${CACHE_DIR}" && chmod 700 "${CACHE_DIR}"
    SECRETS="$(just talos secrets-env)"
    # Cache key: everything the rendered output depends on, including the secrets
    # snapshot mtime so refreshing the 1Password item invalidates the cache.
    KEY="$(cat "${MAIN}/machineconfig.yaml.j2" \
        "${MAIN}/${MACHINE_TYPE}/schematic.yaml" \
        "${MAIN}/${MACHINE_TYPE}/{{ node }}.yaml" \
        "${MAIN}/${MACHINE_TYPE}/${MACHINE_TYPE}.yaml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    OUT="${CACHE_DIR}/render-${MACHINE_TYPE}-$(stat -c %Y "${SECRETS}")-${KEY}.yaml"
    if [ -f "${OUT}" ]; then
        cat "${OUT}"
        exit 0
    fi
    PATCH_ARGS=()
    TYPE_PATCH="${MAIN}/${MACHINE_TYPE}/${MACHINE_TYPE}.yaml"
    if [ -f "${TYPE_PATCH}" ]; then
        PATCH_ARGS+=(-p @"${TYPE_PATCH}")
    fi
    # shellcheck disable=SC1090
    set -a; source "${SECRETS}"; set +a
    TMP="$(mktemp "${CACHE_DIR}/.render.XXXXXX")"
    talosctl machineconfig patch <(just template "${MAIN}/machineconfig.yaml.j2" --strict) \
        "${PATCH_ARGS[@]}" \
        -p @<(just template "${MAIN}/${MACHINE_TYPE}/{{ node }}.yaml" --strict) > "${TMP}"
    chmod 600 "${TMP}"
    mv -f "${TMP}" "${OUT}"
    cat "${OUT}"

[doc('Flush the talos render + secrets caches (they live in tmpfs and die with the session anyway)')]
[script]
flush-cache:
    #!/usr/bin/env bash
    set -euo pipefail
    CACHE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache"
    rm -rf "${CACHE_DIR}"
    just log info "Flushed" "${CACHE_DIR}"

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }}

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
    export MACHINE_TYPE="$(just talos machine-type {{ node }})"
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    # shellcheck disable=SC1090
    set -a; source "$(just talos secrets-env)"; set +a
    just template "{{ source_directory() }}/main/machineconfig.yaml.j2" --strict | yq -e 'select(.machine) | .machine.install.image'

[private]
[doc('Fetch the talos 1Password item (1 API request) and cache it as a sourceable env file in tmpfs (TALOS_SECRETS_TTL seconds, default 3600; 0 forces a refresh). Requires all 14 talos fields; fails on missing or empty ones.')]
[script]
secrets-env:
    #!/usr/bin/env bash
    set -euo pipefail
    CACHE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache"
    CACHE_FILE="${CACHE_DIR}/secrets.env"
    TTL="${TALOS_SECRETS_TTL:-3600}"
    mkdir -p "${CACHE_DIR}" && chmod 700 "${CACHE_DIR}"
    if [ -f "${CACHE_FILE}" ]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "${CACHE_FILE}") ))
        if [ "${AGE}" -lt "${TTL}" ]; then
            echo "${CACHE_FILE}"
            exit 0
        fi
    fi
    TMP="$(mktemp "${CACHE_DIR}/.secrets.XXXXXX")"
    op item get talos --vault home-ops --format json \
        | jq -er '.fields[]
            | select(.label | test("^[A-Z][A-Z0-9_]*$"))
            | select(.value != null)
            | .label + "=" + (.value | @sh)' > "${TMP}"
    chmod 600 "${TMP}"
    REQUIRED="MACHINE_CA_CRT MACHINE_CA_KEY MACHINE_TOKEN CLUSTER_CA_CRT CLUSTER_CA_KEY CLUSTER_ID CLUSTER_SECRET CLUSTER_TOKEN CLUSTER_AGGREGATORCA_CRT CLUSTER_AGGREGATORCA_KEY CLUSTER_ETCD_CA_CRT CLUSTER_ETCD_CA_KEY CLUSTER_SECRETBOXENCRYPTIONSECRET CLUSTER_SERVICEACCOUNT_KEY"
    BROKEN=""
    for field in ${REQUIRED}; do
        grep -q "^${field}=" "${TMP}" || BROKEN="${BROKEN} ${field}(missing)"
    done
    while IFS= read -r line; do
        BROKEN="${BROKEN} ${line%%=*}(empty)"
    done < <(grep -oE "^[A-Z][A-Z0-9_]*=''$" "${TMP}" || true)
    if [ -n "${BROKEN}" ]; then
        rm -f "${TMP}"
        echo "error: invalid 1Password item 'talos' (refusing to render):${BROKEN}" >&2
        exit 1
    fi
    mv -f "${TMP}" "${CACHE_FILE}"
    echo "${CACHE_FILE}"