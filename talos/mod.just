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
[doc('Reboot node')]
reboot-node node:
    talosctl -n {{ node }} reboot -m powercycle

[doc('Render Talos config for a node (rôle inféré par la présence sous nodes/workers, divergences par nœud optionnelles)')]
[script]
render-config node:
    #!/usr/bin/env bash
    set -euo pipefail
    role="controlplane"
    if [ -f "{{ source_directory() }}/main/nodes/workers/{{ node }}.yaml.j2" ]; then role="workers"; fi
    export SCHEMATIC="$(just talos schematic-id {{ node }})"
    SECRETS="$(just talos secrets-env)"
    # Cache (ref #5071): rendu en tmpfs, keyed par les 4 sources + le rôle +
    # le snapshot secrets (mtime) — un input inchangé court-circuite l'appel
    # 1Password autant que le re-rendu.
    CACHE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache"
    src="{{ source_directory() }}"
    SP="$(just talos schematic-file {{ node }})"
    KEY="$(cat "${src}/main/cluster.yaml.j2" \
        "${src}/main/${role}.yaml.j2" \
        "${src}/main/nodes/${role}/{{ node }}.yaml.j2" \
        "${SP}" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    OUT="${CACHE_DIR}/render-${role}-$(stat -c %Y "${SECRETS}")-${KEY}.yaml"
    if [ -f "${OUT}" ]; then
        cat "${OUT}"
        exit 0
    fi
    workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT INT TERM HUP
    # shellcheck disable=SC1090
    set -a; source "${SECRETS}"; set +a
    just template --strict "${src}/main/cluster.yaml.j2" > "$workdir/base.yaml"
    just template --strict "${src}/main/${role}.yaml.j2" > "$workdir/role.yaml"
    # Couche nœud : fichier requis pour tout nœud connu ; le RENDU peut être
    # vide (placeholder comment-only = aucune divergence — vente strippé les
    # commentaires).
    node_j2="${src}/main/nodes/${role}/{{ node }}.yaml.j2"
    if [ ! -f "$node_j2" ]; then
        echo "error: pas de couche nœud pour '{{ node }}' attendu sous nodes/${role}/" >&2; exit 1
    fi
    if grep -Eqv '^[[:space:]]*(#|\{%|\{\{|$|-{3})' "$node_j2"; then
        just template --strict "$node_j2" > "$workdir/node.yaml"
        [ -s "$workdir/node.yaml" ] || { echo "error: contenu réel dans $node_j2 mais rendu vide" >&2; exit 1; }
        PATCH_ARGS=(-p "@$workdir/node.yaml")
    else
        PATCH_ARGS=()
    fi
    [ -s "$workdir/base.yaml" ] || { echo "error: cluster.yaml.j2 rendu vide" >&2; exit 1; }
    [ -s "$workdir/role.yaml" ] || { echo "error: ${role}.yaml.j2 rendu vide" >&2; exit 1; }
    composed="$(talosctl machineconfig patch "$workdir/base.yaml" -p "@$workdir/role.yaml" ${PATCH_ARGS[@]+"${PATCH_ARGS[@]}"})"
    # NB: yq -e sur multi-docs exit 1 si le DERNIER doc ne matche pas (null) —
    # on évalue sans -e et on teste la sortie.
    type="$(echo "$composed" | yq 'select(.machine) | .machine.type' | head -1)"
    [ -n "$type" ] || { echo "error: garde composition — machine.type introuvable" >&2; exit 1; }
    if [ "$role" = controlplane ] && [ "$type" != controlplane ]; then
        echo "error: garde composition — machine.type='$type' attendu 'controlplane'" >&2; exit 1
    fi
    if [ "$role" = workers ] && [ "$type" != worker ]; then
        echo "error: garde composition — machine.type='$type' attendu 'worker'" >&2; exit 1
    fi
    if [ "$role" = controlplane ]; then
        for kind in RawVolumeConfig KubeTalosAPIAccessConfig; do
            [ -n "$(echo "$composed" | yq "select(.kind == \"$kind\") | .kind" | head -1)" ] || {
                echo "error: garde composition — doc $kind manquant (CP)" >&2; exit 1; }
        done
    fi
    lint_dups() {
        local dups
        dups="$(echo "$composed" | yq "$2" | sort | uniq -d)"
        if [ -n "$dups" ]; then echo "error: lint — doublons $1: $dups" >&2; exit 1; fi
    }
    lint_dups "kernel.modules" '.machine.kernel.modules[].name'
    lint_dups "files" '.machine.files[].path'
    lint_dups "apiServer.certSANs" '.cluster.apiServer.certSANs[]'
    lint_dups "etcd.advertisedSubnets" '.cluster.etcd.advertisedSubnets[]'
    mkdir -p "${CACHE_DIR}" && chmod 700 "${CACHE_DIR}"
    TMP="$(mktemp "${CACHE_DIR}/.render.XXXXXX")"
    echo "$composed" > "${TMP}"
    chmod 600 "${TMP}"
    mv -f "${TMP}" "${OUT}"
    cat "${OUT}"

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false {{ args }}

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown node')]
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
schematic-file node:
    #!/usr/bin/env bash
    set -euo pipefail
    # Override per-node (nodes/*/<node>.schematic.yaml.j2), sinon schéma par rôle.
    for f in "{{ source_directory() }}/main"/nodes/*/"{{ node }}.schematic.yaml.j2"; do
        [ -f "$f" ] && { echo "$f"; exit 0; }
    done
    if [ -f "{{ source_directory() }}/main/nodes/workers/{{ node }}.yaml.j2" ]; then
        echo "{{ source_directory() }}/main/worker/schematic.yaml"
    else
        echo "{{ source_directory() }}/main/controlplane/schematic.yaml"
    fi

[private]
[script]
schematic-id node:
    #!/usr/bin/env bash
    set -euo pipefail
    id="$(just template "$(just talos schematic-file {{ node }})" | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" | jq -r '.id')"
    # Garde hex64 (#AI-review) : une réponse factory dégradée (proxy 5xx JSON
    # sans .id) rendrait "null" → se propagerait en installer image invalide.
    echo "$id" | grep -Eq '^[0-9a-f]{64}$' || { echo "error: schematic id inattendu: '$id'" >&2; exit 1; }
    echo "$id"

[private]
[script]
machine-type node:
    #!/usr/bin/env bash
    set -euo pipefail
    NODE_FILE="$(find "{{ source_directory() }}/main/nodes" -name "{{ node }}.yaml.j2" -print -quit)"
    if [ -z "${NODE_FILE}" ]; then
        echo "error: no patch file found for node '{{ node }}' under {{ source_directory() }}/main/nodes/" >&2
        exit 1
    fi
    basename "$(dirname "${NODE_FILE}")"

[private]
[script]
machine-image node:
    #!/usr/bin/env bash
    set -euo pipefail
    # Extraction depuis le rendu COMPOSÉ (base+role+node) — l'override
    # metal-installer de k8s-3 vit dans la couche nœud (revue v2, 🔴3).
    img="$(just talos render-config {{ node }} | yq 'select(.machine) | .machine.install.image' | head -1)"
    echo "$img" | grep -q '^factory.talos.dev/' || { echo "error: image installer inattendue: '$img'" >&2; exit 1; }
    echo "$img"

[doc('Diff sémantique du rendu composé contre la config live du nœud (filet de sécurité, utile au-delà de la vague 7a)')]
[script]
diff-config node:
    #!/usr/bin/env bash
    set -euo pipefail
    workdir="$(mktemp -d)"; trap 'rm -rf "$workdir"' EXIT INT TERM HUP
    just talos render-config {{ node }} > "$workdir/render.yaml"
    talosctl -n {{ node }} get machineconfig v1alpha1 -o jsonpath='{.spec}' > "$workdir/live.yaml"
    # Normalisation : les deux côtés passés par machineconfig patch (defaults
    # de sérialisation identiques), puis documents triés (l'ordre des docs est
    # non-sémantique et diffère entre le rendu et l'apply historique).
    for side in render live; do
        talosctl machineconfig patch "$workdir/$side.yaml" \
            | yq -o=json ea '.' - \
            | jq -sS 'sort_by([.kind // "0machine", .name // ""]) | .[]' \
            > "$workdir/$side.norm.json"
    done
    diff "$workdir/render.norm.json" "$workdir/live.norm.json"

[private]
[doc('Fetch the single `talos` 1Password item once (1 API request), validate its 14 fields, cache as a sourceable env file in tmpfs (TALOS_SECRETS_TTL seconds, default 3600; 0 forces refresh — ref #5071). Echoes the cache path.')]
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

[doc('Flush the talos render + secrets caches (they live in tmpfs and die with the session anyway — ref #5071)')]
[script]
flush-cache:
    #!/usr/bin/env bash
    set -euo pipefail
    CACHE_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/talos-cache"
    rm -rf "${CACHE_DIR}"
    just log info "Flushed" "${CACHE_DIR}"
