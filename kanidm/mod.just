set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Kanidm admin — idm.oxygn.dev
#
# The `kanidm` CLI runs where it is installed; when absent, every command is
# wrapped in a throwaway quay.io/kanidm/kanidm-tools pod (zero install).
# Auth is non-interactive: the idm_admin password comes from the 1Password
# item `kanidm` (field idm_admin_password) via `op`, fed to the hidden
# global `--password` flag / KANIDM_PASSWORD env of the CLI.
#
#   just kanidm bootstrap                    # one-shot: accounts + provision token + 1Password
#   just kanidm onboard nea "Nea" nea@…      # person + groups + reset link
#   just kanidm reset nea                    # re-issue a reset link

KANIDM_URL := "https://idm.oxygn.dev"
KANIDM_IMAGE := "docker.io/kanidm/tools:1.11.2@sha256:877fc564fb78ad9d198252da2efb1415fc8eeea9184135c8def863333511dd21"

[private]
default:
    just -l kanidm

# ── internals ────────────────────────────────────────────────────────────────

# Run one kanidm CLI command as idm_admin (non-interactive).
[private]
cli *args:
    #!/usr/bin/env bash
    set -euo pipefail
    export KANIDM_URL="{{ KANIDM_URL }}"
    export KANIDM_NAME=idm_admin
    export KANIDM_PASSWORD="${KANIDM_PASSWORD:-$(op item get kanidm --vault home-ops --fields idm_admin_password --reveal 2>/dev/null || op read 'op://home-ops/kanidm/idm_admin_password')}"
    if command -v kanidm >/dev/null 2>&1; then
      kanidm login >/dev/null 2>&1 || true
      kanidm {{ quote(args) }}
    else
      kubectl run -n security kanidm-cli-"$RANDOM" --rm -i --restart=Never --pod-running-timeout=5m \
        --env KANIDM_URL="$KANIDM_URL" --env KANIDM_NAME="$KANIDM_NAME" \
        --env KANIDM_PASSWORD="$KANIDM_PASSWORD" \
        --image={{ KANIDM_IMAGE }} --command -- \
        sh -c 'kanidm login >/dev/null 2>&1 && exec kanidm "$@"' _ {{ quote(args) }}
    fi

# ── bootstrap ────────────────────────────────────────────────────────────────

# One-shot bootstrap: recover built-in accounts, create the provision
# service-account + API token, store everything in 1Password, and unblock
# the kanidm-provision controller.
[doc('One-shot Kanidm bootstrap (accounts + provision token + 1Password)')]
[script]
bootstrap:
    set -euo pipefail
    log() { just log info "$@"; }

    # Accepts JSON {"output":"..."} (kanidmd scripting / kanidm -o json),
    # human `new_password: "..."` (kanidmd recover-account tracing line), or
    # a bare opaque token as a last resort.
    extract_secret() {
      local raw="$1" v=""
      v="$(printf '%s' "$raw" | tr -d '\r' | sed -n 's/.*"output": *"\([^"]*\)".*/\1/p' | tail -1)"
      [ -n "$v" ] || v="$(printf '%s' "$raw" | tr -d '\r' | sed -n 's/.*new_password: *"\([^"]*\)".*/\1/p' | tail -1)"
      [ -n "$v" ] || v="$(printf '%s' "$raw" | tr -d '\r' | grep -oE '[A-Za-z0-9._-]{32,}' | tail -1)"
      printf '%s' "$v"
    }

    log "recovering built-in accounts"
    recover() {
      # NB: the top-level `kanidmd recover-account` prints via tracing (human);
      # `kanidmd scripting recover-account` is the machine-parsable JSON path.
      kubectl exec -n security statefulset/kanidm -- kanidmd scripting recover-account "$1"
    }
    admin_raw="$(recover admin)"
    idm_raw="$(recover idm_admin)"
    admin_pw="$(extract_secret "$admin_raw")"
    idm_pw="$(extract_secret "$idm_raw")"
    if [ -z "$admin_pw" ] || [ -z "$idm_pw" ]; then
      echo "failed to parse recover-account output:" >&2
      printf 'admin: %s\nidm_admin: %s\n' "$admin_raw" "$idm_raw" >&2
      exit 1
    fi

    log "storing break-glass passwords in 1Password (item kanidm)"
    OP_VAULT="${KANIDM_OP_VAULT:-$(op vault list --format json 2>/dev/null | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)}"
    if ! op item create --title kanidm --category Login --vault "$OP_VAULT" \
        admin_password="$admin_pw" idm_admin_password="$idm_pw" >/dev/null 2>&1 \
       && ! op item edit --vault "$OP_VAULT" kanidm \
        admin_password="$admin_pw" idm_admin_password="$idm_pw" >/dev/null 2>&1; then
      echo "WARNING: cannot write to 1Password (vault: $OP_VAULT) — store these manually:" >&2
      echo "  item kanidm:  admin_password=$admin_pw  idm_admin_password=$idm_pw" >&2
    fi

    log "creating service-account kanidm-provision"
    export KANIDM_URL="{{ KANIDM_URL }}" KANIDM_NAME=idm_admin KANIDM_PASSWORD="$idm_pw"
    kcli() {
      if command -v kanidm >/dev/null 2>&1; then
        kanidm login >/dev/null 2>&1 || true
        kanidm "$@"
      else
        kubectl run -n security kanidm-cli-"$RANDOM" --rm -i --restart=Never --pod-running-timeout=5m \
          --env KANIDM_URL="$KANIDM_URL" --env KANIDM_NAME="$KANIDM_NAME" \
          --env KANIDM_PASSWORD="$KANIDM_PASSWORD" \
          --image={{ KANIDM_IMAGE }} --command -- \
          sh -c 'kanidm login >/dev/null 2>&1 && exec kanidm "$@"' _ "$@"
      fi
    }
    kcli service-account create kanidm-provision "Kanidm Provision" idm_admins || true
    kcli group add-members idm_admins kanidm-provision || true
    kcli group create users || true
    kcli group create admins || true
    token_raw="$(kcli service-account api-token generate --readwrite kanidm-provision provision-token 2>/dev/null)"
    token="$(extract_secret "$token_raw")"
    if [ -z "$token" ]; then
      echo "failed to parse api-token output:" >&2
      printf '%s\n' "$token_raw" >&2
      exit 1
    fi

    log "storing provision token (1Password + Secret fallback)"
    if ! op item create --title kanidm-provision --category 'API Credential' --vault "$OP_VAULT" \
        token="$token" >/dev/null 2>&1 \
       && ! op item edit --vault "$OP_VAULT" kanidm-provision token="$token" >/dev/null 2>&1; then
      echo "WARNING: cannot write to 1Password — create item kanidm-provision (field token) manually:" >&2
      echo "  token=$token" >&2
    fi
    # Always materialise the Secret directly so the provision controller can
    # start even before the 1Password item exists (the ExternalSecret adopts
    # and re-syncs the same value once the item lands)
    kubectl -n security create secret generic kanidm-provision-token \
      --from-literal=token="$token" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    log "syncing ExternalSecret kanidm-provision-token"
    kubectl -n security annotate externalsecret kanidm-provision-token "force-sync=$(date +%s)" --overwrite

    log "waiting for the provision controller"
    kubectl -n security rollout status deploy/kanidm-provision --timeout=300s
    log "bootstrap complete — now: just kanidm onboard <user> '<Name>' <email>"

# ── people ───────────────────────────────────────────────────────────────────

# Onboard a person: create, add to groups (default users), print the reset link.
[doc('Onboard a person and print their credential reset link')]
onboard user name email +groups="users":
    #!/usr/bin/env bash
    set -euo pipefail
    just kanidm cli person create {{ user }} "{{ name }}"
    just kanidm cli person update {{ user }} --mail {{ email }}
    for g in {{ groups }}; do just kanidm cli group add-members "$g" {{ user }}; done
    echo "### reset link for {{ user }} ###"
    just kanidm cli person credential create-reset-token {{ user }}

# Bulk onboard from CSV: username,Full Name,email,space-separated-groups
[doc('Bulk onboard people from a CSV file')]
bulk file:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS=, read -r user name mail groups; do
      [ -z "${user:-}" ] && continue
      just kanidm onboard "$user" "$name" "$mail" ${groups:-users}
    done < {{ file }}

# (Re)issue a credential reset link (e.g. lost passkey)
[doc('Issue a credential reset link for a person')]
reset user:
    just kanidm cli person credential create-reset-token {{ user }}

# ── groups ───────────────────────────────────────────────────────────────────

[doc('Add a person to a group')]
group-add group user:
    just kanidm cli group add-members {{ group }} {{ user }}

[doc('Remove a person from a group')]
group-rm group user:
    just kanidm cli group remove-members {{ group }} {{ user }}

[doc('List group members')]
members group="users":
    just kanidm cli group list-members {{ group }}

[doc('List all people')]
list:
    just kanidm cli person list

[doc('Show one person')]
get user:
    just kanidm cli person get {{ user }}
