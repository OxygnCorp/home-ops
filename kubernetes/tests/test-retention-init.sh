#!/usr/bin/env bash
# Fixture tests for the claws retention init scripts (devclaw + mainclaw).
#
# The scripts ship as HelmRelease values, so the harness renders them exactly
# like Flux does (kustomize build → HelmRelease values), extracts the init
# command, then executes it inside the SAME container image as the pod
# (extracted from the rendered spec) over synthetic /home/node trees.
#
# This would have caught both incidents:
#   2026-10-23/25 — `$(ls ... | head -1)` under set -e + pipefail → instant
#                   silent crash when the glob matches nothing (empty set)
#   2026-10-27    — newest-file protection drift in the .bak keep-loop
#
# Usage: just kube test-init   (see kubernetes/mod.just)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FAILURES=0

# The in-pod fixture suite: runs the shipped script (/init.sh) over synthetic
# trees and asserts the retention semantics (kept / removed).
# Kept under its own variable so the harness file stays readable.
# shellcheck disable=SC2016
suite_body=$(cat <<'RUNNER'
set -u
pass=0; fail=0
root() { rm -rf /home/node /trace.log; mkdir -p /home/node/.openclaw /kopiaignore; touch /tmp/openclaw.json /kopiaignore/.kopiaignore; }
old_dir() { mkdir -p "$1"; touch -d '2026-01-05 00:00:00' "$1"; }
new_dir() { mkdir -p "$1"; touch "$1"; }
ts() { stat -c %Y "$1" 2>/dev/null || echo missing; }
v() { # v <desc> <rm|keep> <path>
    desc="$1"; want="$2"; p="$3"
    if { [ "$want" = rm ] && [ ! -e "$p" ]; } || { [ "$want" = keep ] && [ -e "$p" ]; }; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL: ${desc} — ${p} (present=$([ -e "$p" ] && echo 1 || echo 0))"
    fi
}
try() { # try <desc> — the shipped init MUST exit 0
    echo "===SCEN: ${1}" >&2
    if sh -x /init.sh 2>>/trace.log; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); echo "FAIL: ${1} — init script crashed (see trace)"
    fi
}

# ==== captures loop ===========================================================
root
try 'captures: empty set survives (2026-10-23 devclaw bug)' \
    && { [ -e /home/node/.openclaw/openclaw.json ] && { pass=$((pass + 1)); } || { fail=$((fail + 1)); echo 'FAIL: config copy step'; }; }
[ "$(stat -c %a /home/node/.openclaw/openclaw.json 2>/dev/null)" = '400' ] \
    && pass=$((pass + 1)) || { fail=$((fail + 1)); echo 'FAIL: chmod 400 not applied'; }
[ -e /home/node/.kopiaignore ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo 'FAIL: .kopiaignore not copied'; }

root
old_dir /home/node/.openclaw.update-captures/doctor-a
new_dir /home/node/.openclaw.update-captures/doctor-b
echo "STATS: a=$(ts /home/node/.openclaw.update-captures/doctor-a) b=$(ts /home/node/.openclaw.update-captures/doctor-b)" >&2
try 'captures: keep newest'
v 'captures: oldest pruned' rm /home/node/.openclaw.update-captures/doctor-a
v 'captures: newest kept' keep /home/node/.openclaw.update-captures/doctor-b

root
old_style="2026-01-05 00:00:00"
mkdir -p /home/node/.openclaw.update-captures/doctor-a /home/node/.openclaw.update-captures/doctor-b
touch -d "$old_style" /home/node/.openclaw.update-captures/doctor-a
touch -d '2026-01-06 00:00:00' /home/node/.openclaw.update-captures/doctor-b
echo "STATS: a=$(ts /home/node/.openclaw.update-captures/doctor-a) b=$(ts /home/node/.openclaw.update-captures/doctor-b)" >&2
try 'captures: all-old set keeps the newest only'
v 'captures: newest (b) kept' keep /home/node/.openclaw.update-captures/doctor-b
v 'captures: non-newest old (a) pruned' rm /home/node/.openclaw.update-captures/doctor-a

# ==== migration .bak loop =====================================================
root
mkdir -p /home/node/.openclaw/agents/main/agent
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak
try 'bak: single old backup is protected (2026-10-27 keep-loop drift)'
v 'bak: single old backup kept' keep /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak

root
mkdir -p /home/node/.openclaw/agents/main/agent
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak
touch /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-2.bak
echo "STATS: b1=$(ts /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak) b2=$(ts /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-2.bak)" >&2
try 'bak: newest kept, older pruned'
v 'bak: newest (2) kept' keep /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-2.bak
v 'bak: older (1) pruned' rm /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak

root
mkdir -p /home/node/.openclaw/agents/alpha/agent /home/node/.openclaw/agents/beta/agent
old_dir /home/node/.openclaw/agents/alpha/agent
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-1.bak
touch /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-2.bak
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/beta/agent/x.pre-startup-migration-1.bak
echo "STATS: alpha1=$(ts /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-1.bak) alpha2=$(ts /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-2.bak) beta1=$(ts /home/node/.openclaw/agents/beta/agent/x.pre-startup-migration-1.bak)" >&2
try 'bak: newest is per-agent-dir (two dirs)'
v 'bak: alpha newest (2) kept' keep /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-2.bak
v 'bak: alpha old (1) pruned' rm /home/node/.openclaw/agents/alpha/agent/x.pre-startup-migration-1.bak
v 'bak: beta single old kept (newest of its dir)' keep /home/node/.openclaw/agents/beta/agent/x.pre-startup-migration-1.bak

# ==== captures: content age beats dir age ====================================
# A capture dir's own mtime stops moving once doctor is done writing, so
# retention has to look at the files inside: a dir that *looks* old but holds
# a fresh file is still a recovery artifact and must survive.
root
mkdir -p /home/node/.openclaw.update-captures/doctor-old
mkdir -p /home/node/.openclaw.update-captures/doctor-mixed
touch -d '2026-01-05 00:00:00' /home/node/.openclaw.update-captures/doctor-old/state.json
touch -d '2026-01-05 00:00:00' /home/node/.openclaw.update-captures/doctor-mixed/state.json
touch /home/node/.openclaw.update-captures/doctor-mixed/config.json
# Dir mtimes last: creating a file inside refreshes the parent's mtime.
touch -d '2026-01-05 00:00:00' /home/node/.openclaw.update-captures/doctor-old
touch -d '2026-01-05 00:00:00' /home/node/.openclaw.update-captures/doctor-mixed
mkdir -p /home/node/.openclaw.update-captures/doctor-fresh
try 'captures: content age wins over dir age'
v 'captures: old capture pruned' rm /home/node/.openclaw.update-captures/doctor-old
v 'captures: old dir with a fresh file kept' keep /home/node/.openclaw.update-captures/doctor-mixed
v 'captures: newest kept' keep /home/node/.openclaw.update-captures/doctor-fresh

# ==== state db backups: newest per class =====================================
# doctor cron leaves one copy a day and every startup migration leaves one
# more next to the live DB (13 copies / 888M for a 77M DB on mainclaw,
# 2026-11-23). Keep the newest of each known class; an unknown class must be
# left alone — the prune only knows the two it ships.
root
mkdir -p /home/node/.openclaw/state
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak
touch /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-2.bak
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-aaa.bak
touch /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-bbb.bak
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/state/openclaw.sqlite.unknown-class.bak
try 'state baks: per-class retention'
v 'state bak: newest doctor-cron kept' keep /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-2.bak
v 'state bak: older doctor-cron pruned' rm /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak
v 'state bak: newest migration kept' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-bbb.bak
v 'state bak: older migration pruned' rm /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-aaa.bak
v 'state bak: unknown class untouched' keep /home/node/.openclaw/state/openclaw.sqlite.unknown-class.bak

# ==== legacy one-off sqlite snapshots ========================================
root
mkdir -p /home/node/.openclaw/agents/main/agent
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/main/agent/openclaw-agent.sqlite.bak-20260105000000
touch /home/node/.openclaw/agents/main/agent/openclaw-agent.sqlite.bak-20261123000000
try 'legacy sqlite snapshots: 30d window'
v 'legacy snapshot: older than 30d pruned' rm /home/node/.openclaw/agents/main/agent/openclaw-agent.sqlite.bak-20260105000000
v 'legacy snapshot: recent kept' keep /home/node/.openclaw/agents/main/agent/openclaw-agent.sqlite.bak-20261123000000

# ==== npm cache + logs =======================================================
# The cache is dropped whole above 500M (a per-file prune leaves dangling
# index entries), so the fixture has to cross the threshold for real.
root
mkdir -p /home/node/.npm/_cacache /home/node/.npm/_logs
head -c 600000000 /dev/zero > /home/node/.npm/_cacache/blob.bin
touch -d '2026-01-05 00:00:00' /home/node/.npm/_logs/old.log
touch /home/node/.npm/_logs/fresh.log
try 'npm: oversized cacache dropped whole'
v 'npm: cacache above 500M dropped' rm /home/node/.npm/_cacache
v 'npm: old log pruned' rm /home/node/.npm/_logs/old.log
v 'npm: fresh log kept' keep /home/node/.npm/_logs/fresh.log

root
mkdir -p /home/node/.npm/_cacache
head -c 1000000 /dev/zero > /home/node/.npm/_cacache/blob.bin
try 'npm: small cacache survives'
v 'npm: cacache below 500M kept' keep /home/node/.npm/_cacache

# ==== plugin captures (7d) + import archive (30d, devclaw only) ===============
root
mkdir -p /home/node/.openclaw/tmp/plugin-captures/old-entry
mkdir -p /home/node/.openclaw/tmp/plugin-captures/fresh-entry
touch -d '2026-01-05 00:00:00' /home/node/.openclaw/tmp/plugin-captures/old-entry
touch /home/node/.openclaw/tmp/plugin-captures/fresh-entry
try 'plugin-captures (7d) window'
v 'plugin-captures: old entry pruned' rm /home/node/.openclaw/tmp/plugin-captures/old-entry
v 'plugin-captures: fresh entry kept' keep /home/node/.openclaw/tmp/plugin-captures/fresh-entry

# Only devclaw ran the JSONL -> sqlite import, so only its init ships the
# archive sweep: assert it where it exists instead of testing mainclaw for a
# rule it does not have.
if grep -q 'session-sqlite-import-archive' /init.sh 2>/dev/null; then
    root
    mkdir -p /home/node/.openclaw/agents/main/session-sqlite-import-archive
    touch -d '2026-01-05 00:00:00' /home/node/.openclaw/agents/main/session-sqlite-import-archive/old.jsonl.imported-1788167144331
    touch /home/node/.openclaw/agents/main/session-sqlite-import-archive/fresh.jsonl.imported-1795000000000
    try 'import archive: 30d window'
    v 'import archive: old file pruned' rm /home/node/.openclaw/agents/main/session-sqlite-import-archive/old.jsonl.imported-1788167144331
    v 'import archive: fresh file kept' keep /home/node/.openclaw/agents/main/session-sqlite-import-archive/fresh.jsonl.imported-1795000000000
else
    echo "SKIP: import archive sweep (not shipped by this init script)" >&2
fi

# ==== idempotence ============================================================
# The init runs on every start, so a second pass over an already-pruned tree
# must be a no-op and still exit 0.
root
mkdir -p /home/node/.openclaw/agents/main/agent
touch /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak
try 'idempotent: first run'
try 'idempotent: second run on the same tree'
v 'idempotent: protected backup still present' keep /home/node/.openclaw/agents/main/agent/x.pre-startup-migration-1.bak

echo "TAGG:RESULT pass=${pass} fail=${fail}"
if [ "$fail" -ne 0 ]; then echo "==== TRACE ===="; cat /trace.log 2>/dev/null | tail -80; fi
[ "$fail" -eq 0 ]
RUNNER
)

run_pod_suite() { # run_pod_suite <app-name> <init-script-file> <image-ref>
    local app="$1" script="$2" image="$3"
    local name="${app}-retention-test-$(date +%s)"
    local init_b64 suite_b64
    init_b64=$(base64 -w0 "$script")
    suite_b64=$(printf '%s' "$suite_body" | base64 -w0)

    echo "=== ${app} (${image}) ===" >&2

    kubectl delete pod -n ai "${name}" --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -n ai -f - <<POD
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
spec:
  restartPolicy: Never
  containers:
  - name: t
    image: ${image}
    command:
    - sh
    - -c
    - printf '%s' '${init_b64}' | base64 -d > /init.sh; printf '%s' '${suite_b64}' | base64 -d > /suite.sh; sh /suite.sh
POD

    # Wait for terminal phase (Succeeded only lands at rc=0).
    local phase=""
    for _ in $(seq 1 60); do
        phase=$(kubectl get pod -n ai "${name}" -o jsonpath='{.status.phase}')
        [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ] && break
        sleep 2
    done

    local rc
    rc=$(kubectl get pod -n ai "${name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
    if [ -n "$rc" ] && [ "$rc" != "0" ]; then
        # full suite log incl. traces for the failing scenario
        kubectl logs -n ai "${name}" | sed 's/^/  /' || true
    else
        kubectl logs -n ai "${name}" | grep -E 'TAGG|STATS' | sed 's/^/  /' || true
    fi
    kubectl delete pod -n ai "${name}" --wait=false --ignore-not-found >/dev/null 2>&1 || true

    if [ "$rc" != "0" ]; then
        echo "FAIL: ${app} fixture suite exited (rc=${rc:-none})" >&2
        return 1
    fi
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for app in devclaw mainclaw; do
    app_dir="kubernetes/apps/ai/${app}/app"
    hr='select(.kind=="HelmRelease")'
    init='.spec.values.controllers.openclaw.initContainers.init'

    rendered=$(kustomize build "${app_dir}" --load-restrictor=LoadRestrictionsNone)

    # The exact container image the init runs in (tag embeds the digest ref).
    image=$(printf '%s' "$rendered" | yq "${hr} | ${init}.image.repository + \":\" + ${init}.image.tag")

    # The exact shipped script.
    printf '%s' "$rendered" | yq "${hr} | ${init}.command[2]" > "${work}/${app}-init.sh"
    # yq preserves the block-scalar indentation — normalize it.
    sed -i -e 's/^[[:space:]]*//' "${work}/${app}-init.sh"
    sh -n "${work}/${app}-init.sh"

    if run_pod_suite "$app" "${work}/${app}-init.sh" "$image"; then
        echo "PASS: ${app}"
    else
        FAILURES=$((FAILURES + 1))
        echo "FAIL: ${app}"
    fi
done

echo "=== ${FAILURES} failing app(s)"
[ "$FAILURES" -eq 0 ]
