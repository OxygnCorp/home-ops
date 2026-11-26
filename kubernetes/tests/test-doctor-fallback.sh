#!/usr/bin/env bash
# Fixture tests the SQLITE_CORRUPT self-heal shipped in the claws' app
# startup command (devclaw + mainclaw).
#
# The region under test sits between the anchors "# Doctor check and fix
# any issues" and "# Start gateway" of the rendered app container command:
# the doctor invocation teed to /tmp/doctor.log, the corruption-signature
# gate, and the state-DB fallback that swaps the newest valid
# openclaw.sqlite.*.bak in.
#
# 2026-11-26 — devclaw crashlooped 101 restarts on "database disk image
# is malformed" (ERR_SQLITE_ERROR 11) after a pod death mid-migration
# (Recreate + RWO): doctor refused maintenance, the startup deliberately
# continued, and the gateway died on its own integrity check ~14 s in;
# only a state-mounting one-off Job could clear it. This suite pins the
# in-pod self-heal that replaces that manual recovery:
#   - corruption gate keys on the SQLite signature, NOT doctor's exit
#     code (a plugin/perms failure must never cost DB state)
#   - newest valid .bak wins; non-SQLite captures are never swapped in
#   - corrupt live DB and proven-bad restore points kept as
#     .corrupt-<ts> for forensics, retired so next boot tries the next
#     candidate instead of looping on the same one
#
# Usage: just kube test-fallback (see kubernetes/mod.just)

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

FAILURES=0

# in-pod fixture suite: runs the extracted region (/region.sh) over
# synthetic state trees with a stubbed node dispatching scripted doctor
# outputs. Kept under its own variable so the harness stays readable.
# shellcheck disable=SC2016
suite_body=$(cat <<'RUNNER'
set -u
pass=0; fail=0
first() { # first <glob> — first existing match, or nothing
  for f in $1; do [ -f "$f" ] && { printf '%s' "$f"; return 0; }; done
  return 1
}
root() {
  rm -rf /home/node /stub
  mkdir -p /home/node/.openclaw/state /stub/bin
  rm -f /tmp/doctor.log /tmp/doctor-retry.log /tmp/region.out
}
bak() { # bak <file> <healthy|garbage> <marker> [date]
  if [ "$2" = healthy ]; then printf 'SQLite format 3\0%s\n' "$3" > "$1"; else printf '%s\n' "$3" > "$1"; fi
  [ -n "${4:-}" ] && touch -d "$4" "$1" || true
}
doctor_out() { printf '%s\n' "$1" > /stub/doctor-out; printf '%s' "$2" > /stub/doctor-rc; }
try() { # try <desc> — extracted region MUST exit 0
  echo "===SCEN: ${1}" >&2
  if PATH="/stub/bin:${PATH}" sh -x /region.sh > /tmp/region.out 2>>/trace.log; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: ${1} — region crashed (see trace)"
  fi
}
has() { # has <desc> <needle> <file>
  if grep -q "$2" "$3" 2>/dev/null; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${1} — ${3} lacks: ${2}"; fi
}
lacks() { # lacks <desc> <needle> <file>
  if grep -q "$2" "$3" 2>/dev/null; then fail=$((fail + 1)); echo "FAIL: ${1} — ${3} unexpectedly has: ${2}"; else pass=$((pass + 1)); fi
}
v() { # v <desc> <rm|keep> <path>
  desc="$1"; want="$2"; p="$3"
  if { [ "$want" = rm ] && [ ! -e "$p" ]; } || { [ "$want" = keep ] && [ -e "$p" ]; }; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: ${desc} — ${p} (present=$([ -e "$p" ] && echo 1 || echo 0))"
  fi
}
calls() { # calls <desc> <want> — stubbed doctor invocations
  got=$(wc -l < /stub/node-calls 2>/dev/null || echo 0)
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${1} — doctor calls=${got} want=${2}"; fi
}
assert_mode() { # assert_mode <desc> <want mode> <path>
  got=$(stat -c %a "$3" 2>/dev/null || echo missing)
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ${1} — ${3} mode=${got} want=${2}"; fi
}

corrupt_sig='Doctor could not enter maintenance. failed to acquire gateway state ownership | database disk image is malformed | ERR_SQLITE_ERROR (code=ERR_SQLITE_ERROR, errcode=11)
SQLite integrity_check failed for /home/node/.openclaw/state/openclaw.sqlite: database disk image is malformed (code=ERR_SQLITE_ERROR, errcode=11)'
healthy_sig='Doctor: startup
Doctor: archive preparation
Doctor: complete'
plugin_sig='Doctor: startup
WARN: plugin marketplace unreachable (fixture: doctor failure without corruption markers)'

# stub node — counts every call, dispatches doctor args to scripted
# fixtures; an optional /stub/doctor-out-retry scripts the second call
# (the post-restore doctor retry).
cat > /stub/bin/node <<'STUB'
#!/bin/sh
echo "$*" >> /stub/node-calls
case " $* " in
  *" doctor "*)
    if [ -f /stub/doctor-out-retry ] && [ "$(wc -l < /stub/node-calls)" -ge 2 ]; then
      cat /stub/doctor-out-retry; exit "$(cat /stub/doctor-rc-retry)"
    fi
    cat /stub/doctor-out; exit "$(cat /stub/doctor-rc)"
    ;;
esac
exit 0
STUB
chmod +x /stub/bin/node

# ==== S1: corrupt + baks of both classes: newest valid wins =========
root
printf 'CORRUPT-DATA\n' > /home/node/.openclaw/state/openclaw.sqlite
printf 'WALJUNK' > /home/node/.openclaw/state/openclaw.sqlite-wal
printf 'SHMJUNK' > /home/node/.openclaw/state/openclaw.sqlite-shm
bak /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak healthy HEALTHY-OLD '2026-01-05 00:00:00'
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak healthy HEALTHY-NEW
doctor_out "$corrupt_sig" 1
printf 'Doctor: complete\n' > /stub/doctor-out-retry
printf '0' > /stub/doctor-rc-retry
try 'S1 corrupt + baks: newest valid restored'
has 'S1 live db restored' HEALTHY-NEW /home/node/.openclaw/state/openclaw.sqlite
lacks 'S1 corrupt data gone' CORRUPT-DATA /home/node/.openclaw/state/openclaw.sqlite
assert_mode 'S1 live db mode 600 (sqlite rw for owner)' 600 /home/node/.openclaw/state/openclaw.sqlite
v 'S1 stale wal removed' rm /home/node/.openclaw/state/openclaw.sqlite-wal
v 'S1 stale shm removed' rm /home/node/.openclaw/state/openclaw.sqlite-shm
v 'S1 used bak still present (only bad restores retire)' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak
v 'S1 other bak untouched' keep /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak
cf=$(first '/home/node/.openclaw/state/openclaw.sqlite.corrupt-*')
if [ -n "$cf" ]; then has 'S1 corrupt live kept for forensics' CORRUPT-DATA "$cf"; else fail=$((fail + 1)); echo 'FAIL: S1 corrupt live not preserved'; fi
has 'S1 restore announced' 'state DB corrupt: restoring' /tmp/region.out
has 'S1 doctor warn teed' 'WARN: doctor exited nonzero' /tmp/doctor.log
has 'S1 signature captured' 'database disk image is malformed' /tmp/doctor.log
calls 'S1 doctor + one retry' 2

# ==== S2: corrupt + no baks: warn, live untouched ====================
root
printf 'CORRUPT-DATA\n' > /home/node/.openclaw/state/openclaw.sqlite
doctor_out "$corrupt_sig" 1
try 'S2 corrupt + no bak: continue without swap'
has 'S2 live db untouched' CORRUPT-DATA /home/node/.openclaw/state/openclaw.sqlite
cf=$(first '/home/node/.openclaw/state/openclaw.sqlite.corrupt-*')
if [ -z "$cf" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo 'FAIL: S2 live db moved without a restore point'; fi
has 'S2 no-valid-backup warn' 'no valid state backup' /tmp/region.out
calls 'S2 no retry without restore' 1

# ==== S3: healthy doctor: no swap ====================================
root
printf 'LIVE-OK\n' > /home/node/.openclaw/state/openclaw.sqlite
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak healthy HEALTHY-NEW
doctor_out "$healthy_sig" 0
try 'S3 healthy: no swap'
has 'S3 live db untouched' LIVE-OK /home/node/.openclaw/state/openclaw.sqlite
lacks 'S3 no announce' 'state DB corrupt' /tmp/region.out
v 'S3 bak untouched' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak
[ -f /tmp/doctor.log ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo 'FAIL: S3 doctor log missing'; }
calls 'S3 single doctor call' 1

# ==== S4: doctor fails without markers: no swap (gate is on ========
# ==== the signature, not the exit code) ==============================
root
printf 'LIVE-OK\n' > /home/node/.openclaw/state/openclaw.sqlite
doctor_out "$plugin_sig" 1
try 'S4 non-corruption failure: no swap'
has 'S4 live db untouched' LIVE-OK /home/node/.openclaw/state/openclaw.sqlite
cf=$(first '/home/node/.openclaw/state/openclaw.sqlite.corrupt-*')
if [ -z "$cf" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo 'FAIL: S4 non-corruption failure moved live db'; fi
has 'S4 doctor warn teed' 'WARN: doctor exited nonzero' /tmp/doctor.log
calls 'S4 single doctor call' 1

# ==== S5: newest bak is garbage: older valid one wins ================
root
printf 'CORRUPT-DATA\n' > /home/node/.openclaw/state/openclaw.sqlite
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-2.bak garbage TRUNCATED-CAPTURE
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak healthy HEALTHY-OLD '2026-01-05 00:00:00'
doctor_out "$corrupt_sig" 1
printf 'Doctor: complete\n' > /stub/doctor-out-retry
printf '0' > /stub/doctor-rc-retry
try 'S5 garbage newest skipped'
has 'S5 older valid bak restored' HEALTHY-OLD /home/node/.openclaw/state/openclaw.sqlite
lacks 'S5 garbage never swapped in' TRUNCATED-CAPTURE /home/node/.openclaw/state/openclaw.sqlite
v 'S5 garbage bak left in place' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-2.bak
v 'S5 used bak kept (restore was good)' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak
calls 'S5 retry doctor after restore' 2

# ==== S6: only garbage baks: no swap =================================
root
printf 'CORRUPT-DATA\n' > /home/node/.openclaw/state/openclaw.sqlite
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak garbage TRUNCATED
doctor_out "$corrupt_sig" 1
try 'S6 only invalid baks: no swap'
has 'S6 live db untouched' CORRUPT-DATA /home/node/.openclaw/state/openclaw.sqlite
has 'S6 no-valid-backup warn' 'no valid state backup' /tmp/region.out
v 'S6 garbage bak untouched' keep /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak
calls 'S6 no retry' 1

# ==== S7: restore point itself corrupt: retire it, next boot ========
# ==== falls back to the next candidate ===============================
root
printf 'CORRUPT-DATA\n' > /home/node/.openclaw/state/openclaw.sqlite
bak /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak healthy HEALTHY-BUT-BAD
bak /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak healthy HEALTHY-OLD '2026-01-05 00:00:00'
doctor_out "$corrupt_sig" 1
# no doctor-out-retry: the second call reports the same corruption
try 'S7 bak that restores to corruption is retired'
has 'S7 live db is the bak content' HEALTHY-BUT-BAD /home/node/.openclaw/state/openclaw.sqlite
v 'S7 spent bak retired' rm /home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-1.bak
rf=$(first '/home/node/.openclaw/state/openclaw.sqlite.pre-startup-migration-*.corrupt-*')
if [ -n "$rf" ]; then has 'S7 retired bak kept for forensics' HEALTHY-BUT-BAD "$rf"; else fail=$((fail + 1)); echo 'FAIL: S7 retired bak missing'; fi
cf=$(first '/home/node/.openclaw/state/openclaw.sqlite.corrupt-*')
if [ -n "$cf" ]; then has 'S7 original corrupt live kept' CORRUPT-DATA "$cf"; else fail=$((fail + 1)); echo 'FAIL: S7 original corrupt live not preserved'; fi
v 'S7 other bak still a candidate next boot' keep /home/node/.openclaw/state/openclaw.sqlite.doctor-cron-1.bak
has 'S7 still-failing warn' 'doctor still failing' /tmp/doctor-retry.log
calls 'S7 retry doctor happened' 2

echo "TAGG:RESULT pass=${pass} fail=${fail}"
if [ "$fail" -ne 0 ]; then echo "==== TRACE ===="; tail -80 /trace.log 2>/dev/null; fi
[ "$fail" -eq 0 ]
RUNNER
)

run_pod_suite() { # run_pod_suite <app> <region-file> <image-ref>
  local app="$1" script="$2" image="$3"
  local name="${app}-fallback-test-$(date +%s)"
  local region_b64 suite_b64
  region_b64=$(base64 -w0 "$script")
  suite_b64=$(printf '%s' "$suite_body" | base64 -w0)

  echo "=== ${app} (${image})" >&2

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
      # the real startup runs as the gateway uid; the region under test
      # only rewrites files it owns, and the fixture trees are built by
      # the suite itself, so run as root like the retention-init suite
      # (also the only way /region.sh and /suite.sh can be dropped in /).
      securityContext:
        runAsUser: 0
      command:
        - sh
        - -c
        - printf '%s' '${region_b64}' | base64 -d > /region.sh; printf '%s' '${suite_b64}' | base64 -d > /suite.sh; sh /suite.sh
POD

  # Wait for terminal phase (Succeeded only lands at rc=0).
  local phase=""
  for _ in $(seq 1 60); do
    phase=$(kubectl get pod -n ai "${name}" -o jsonpath='{.status.phase}')
    { [ "$phase" = "Succeeded" ] || [ "$phase" = "Failed" ]; } && break
    sleep 2
  done

  local rc
  rc=$(kubectl get pod -n ai "${name}" -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null || true)
  if [ -n "$rc" ] && [ "$rc" != "0" ]; then
    # full suite log incl. traces of failing scenarios
    kubectl logs -n ai "${name}" | sed 's/^/ /' || true
  else
    kubectl logs -n ai "${name}" | grep -E 'TAGG|SCEN' | sed 's/^/ /' || true
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
  app_cmd='.spec.values.controllers.openclaw.containers.app'

  rendered=$(kustomize build "${app_dir}" --load-restrictor=LoadRestrictionsNone)

  # exact container image the startup command runs in (tag embeds digest ref).
  image=$(printf '%s' "$rendered" | yq "${hr} | ${app_cmd}.image.repository + \":\" + ${app_cmd}.image.tag")

  # exact shipped script, normalized flat like the pod would see it.
  printf '%s' "$rendered" | yq "${hr} | ${app_cmd}.command[2]" | sed 's/^[[:space:]]*//' > "${work}/${app}-app.sh"

  # The anchors delimiting the doctor region must each match exactly
  # once — a reworded comment silently widening or splitting the
  # extraction is a hard failure, not a test quirk.
  for anchor in '^# Doctor check and fix any issues' '^# Start gateway'; do
    n=$(grep -c "$anchor" "${work}/${app}-app.sh" || true)
    if [ "$n" != "1" ]; then
      echo "FAIL: ${app}: anchor ${anchor} matched ${n} times — extraction ambiguous" >&2
      FAILURES=$((FAILURES + 1))
      continue 2
    fi
  done

  # doctor region: the teed doctor invocation + the SQLITE_CORRUPT
  # fallback, up to (excluding) the gateway start.
  sed -n '/^# Doctor check and fix any issues/,/^# Start gateway/{/^# Start gateway/!p}' "${work}/${app}-app.sh" > "${work}/${app}-region.sh"
  sh -n "${work}/${app}-region.sh"

  if run_pod_suite "$app" "${work}/${app}-region.sh" "$image"; then
    echo "PASS: ${app}"
  else
    FAILURES=$((FAILURES + 1))
    echo "FAIL: ${app}"
  fi
done

echo "=== ${FAILURES} failing app(s)"
[ "$FAILURES" -eq 0 ]
