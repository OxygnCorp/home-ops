#!/usr/bin/env bash
# Shared AI-review automerge gate decision logic.
# Used by:
#   - .github/workflows/ai-pr-review.yaml          (job automerge-gate — the
#     REQUIRED check's own Actions job; conclusion = job exit code)
#   - .github/workflows/ai-pr-review-labels.yaml   (job gate-refresh — the same
#     decision reproduced and POSTED as a check-run named exactly
#     "AI PR Review (automerge gate)" via the checks API; see that file)
#
# Contract: exit 0 = gate passes, exit 1 = gate blocks (fail-closed).
# Env: GH_TOKEN, PR_NUMBER, REVIEW_RESULT, GATE_POLL_*, and optionally
# GATE_REVIEW_WORKFLOW_NAME (the workflow that runs the review job — the
# labels workflow must point it at the MAIN workflow's name to see its
# in-flight review runs; defaults to the calling workflow's own name).
set -o pipefail
command -v gh >/dev/null || { echo "::error::gh not available on runner"; exit 1; }
command -v jq >/dev/null || { echo "::error::jq not available on runner"; exit 1; }

: "${GATE_REVIEW_WORKFLOW_NAME:=${GITHUB_WORKFLOW}}"

# ── Shared helpers for the `skipped` decision branch below.
# Rename note: the review job's display name is duplicated below on
# purpose — the `needs` context exposes no job `name` field, so a
# context lookup would silently evaluate empty string and dead-code
# the whole pre-verdict poll (caught in review). If either job name
# below changes, change all of them together.
review_job_name='AI PR Review'
# NOTE: no `gh api --slurp` here — the ARC runner's gh predates it
# (`--slurp` failed with a usage dump in production, PR #5424), so
# both counts use the two paginated `--jq` calls below. `--jq`
# applies PER PAGE, hence the awk page-wise summation; a literal
# multi-line "0\n3" with [[ "$x" -gt 0 ]] is a silent bash
# arithmetic failure — false — the direction this gate must
# never fail in.
scan_reviews() {
  reviewed="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews?per_page=100" --paginate --jq \
    "[.[] | select(.author.type == \"Bot\" and (.body | startswith(\"${marker}\")) and .commit_id == \"${head_sha}\")] | length" \
    | awk '{s+=$1} END{print s+0}')" \
    || return 1
  blockers="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}/reviews?per_page=100" --paginate --jq \
    "[.[] | select(.author.type == \"Bot\" and (.body | startswith(\"${marker}\")) and .commit_id == \"${head_sha}\" and .state == \"CHANGES_REQUESTED\" and (.body | contains(\"${notice}\") | not))] | length" \
    | awk '{s+=$1} END{print s+0}')" \
    || return 1
}
# True (0) iff some in-flight run of the review workflow (see
# GATE_REVIEW_WORKFLOW_NAME) is running, or has not yet registered, its
# review job. Runs whose review job already completed (an infra-failed
# run) can never publish a verdict, so they must neither keep the gate
# waiting nor let it pass; a run with NO jobs yet is counted as coming
# (it may be a queued review run; a skip-run registers its completed
# review job within seconds and stops matching). Exit code > 1 reports
# API failure — handled with tolerance at call sites, fail-closed in
# the limit.
review_in_flight() {
  local ids id state
  ids="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs?head_sha=${head_sha}&per_page=100" --paginate --jq \
    '[.workflow_runs[] | select(.name == "'"${GATE_REVIEW_WORKFLOW_NAME}"'" and .id != '"${GITHUB_RUN_ID}"' and .status != "completed") | .id] | .[]' )" \
    || return 2
  for id in $ids; do
    state="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${id}/jobs?filter=latest" --jq \
      "[.jobs[] | select(.name == \"${review_job_name}\")] | {n: length, dirty: any(.status == \"queued\" or .status == \"in_progress\")}")" \
      || return 3
    case "$state" in
      *'"dirty":true'*) return 0 ;;
      *'"n":0'*) return 0 ;;
    esac
  done
  return 1
}

# Re-read the live `hold` flag. The entry check above is a snapshot: the
# labels workflow (.github/workflows/ai-pr-review-labels.yaml) can add
# or remove `hold` CONCURRENTLY with an in-flight gate, and a green
# published from stale entry-state would silently override a hold added
# while this gate waited on a verdict. Every SLOW (polling) pass path
# re-checks before publishing green; the fast paths sit within seconds
# of the entry snapshot, so they do not re-check.
hold_present() {
  gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq \
    '[.labels[]?.name | ascii_downcase] | any(. == "hold")'
}

pr="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}")" \
  || { echo "::error::could not read PR #${PR_NUMBER} metadata"; exit 1; }
head_sha="$(echo "$pr" | jq -r .head.sha)"
head_ref="$(echo "$pr" | jq -r .head.ref)"
# Publish the decision's anchor SHA (GATE_STATE_FILE published by the caller).
# Everything below is decided AGAINST this snapshot; the caller (the labels
# workflow's gate-refresh) checks before POSTing that the live head SHA has
# not moved, so a decision made for one SHA can never be published on
# another. The main workflow does not need this — its check-run is an
# Actions run naturally bound to the run's head SHA.
if [[ -n "${GATE_STATE_FILE:-}" ]]; then
  printf '%s' "$head_sha" > "$GATE_STATE_FILE" 2>/dev/null || true
fi

# ── `hold` label: manual holding pattern, independent of the AI review
# verdict (branch decision table below it). Applies to ANY PR —
# Renovate or human: Renovate ignores labels for its automerge
# decision, so a manual hold is only real when it surfaces through
# this required check. ADD/REMOVE of the label no longer re-runs the
# main workflow (the `labeled`/`unlabeled` trigger types are gone);
# the labels workflow posts/refreshes the required check for those
# events, and removal re-arms a full review there — so the
# unblock is still self-healing.
# Case-insensitive on `hold` to mirror the job-level `contains()`.
hold="$(echo "$pr" | jq -r '[.labels[]?.name | ascii_downcase] | any(. == "hold")')" \
  || { echo "::error::could not evaluate PR labels for 'hold'"; exit 1; }
if [[ "$hold" == "true" ]]; then
  echo "::error::PR carries the 'hold' label — merge is manually held (block independent of the AI review). Remove the label to re-open the gate."
  exit 1
fi

if [[ "$head_ref" != renovate/am-* ]]; then
  echo "Not a Renovate automerge branch: gate passes (humans are not gated, unless 'hold')."
  exit 0
fi

# Digest bumps are not AI-gated by policy: Renovate labels its
# digest update PRs with type/digest (.renovate/labels.json5) and
# admits them to the trusted automerge set on their own
# (.renovate/autoMerge.json5). The review job skips them (see the
# job comment) so no verdict exists to consult — the gate passes
# before any REVIEW_RESULT handling, whatever its value. Checked
# against the live payload as `hold`. Same trust anchor as the
# job if: the PR must be on a trusted-prefixed branch AND authored
# by Renovate itself (`mushu-bot[bot]` Bot type) — a hand-decorated
# PR (any collaborator can label) never satisfies authorship.
#
# Accepted edge: if a one-time review ran before the label
# existed (or on an am-, non-digest PR later re-purposed) and
# published a REQUEST_CHANGES, this pass-check outranks that
# verdict — the stale review remains visible on the PR timeline
# (it blocks the merge button only where review protections
# apply) but the required check greens upon any subsequent
# event. m2-style residue, documented.
digest="$(echo "$pr" | jq -r '(.user.login == "mushu-bot[bot]") and (.user.type == "Bot") and ([.labels[]?.name | ascii_downcase] | any(. == "type/digest"))')" \
  || { echo "::error::could not evaluate PR authorship/labels for the digest exemption"; exit 1; } \
  || { echo "::error::could not evaluate PR labels for 'type/digest'"; exit 1; }
if [[ "$digest" == "true" ]]; then
  echo "Renovate-authored digest automerge branch (label type/digest): not AI-gated by policy — gate passes."
  exit 0
fi

case "$REVIEW_RESULT" in
  success)
    echo "Review verdict clean (or fail-open degraded): gate passes."
    exit 0
    ;;
  failure|cancelled)
    echo "::error::AI review failed or was cancelled on a Renovate automerge branch — blocking automerge. Re-review via the 'ai-review' label or a rebase."
    exit 1
    ;;
  skipped)
    # Preserves a previously published verdict on this head SHA across
    # events that skip the LLM review itself (draft, or non-ai-review
    # label events historic — now: digest/draft runs).
    #
    # Managed-review identity matches the action's own contract
    # (src/metadata/markers.ts isManagedBody): Bot-authored AND body
    # starting with the "<!-- ai-pr-review" HTML marker, which covers
    # both the current marker and the legacy "<!-- ai-pr-reviewer"
    # prefix. Content-based identity is what upstream itself uses
    # (#190): author identity can change across token types, and
    # author.type == "Bot" alone would count a foreign App review
    # (e.g. Copilot) — Bot matches humans out, marker matches foreign
    # Apps out.
    #
    # Fore-seen open blockers BLOCK. The action's model-outage notice
    # publishes a managed CHANGES_REQUESTED review (verified
    # src/prompt/failure.ts); it MUST NOT gate — the chosen policy is
    # fail-open on a pure LLM outage per operator decision. Such a
    # notice is identifiable by its fixed first heading
    # ("## AI review could not run", modelFailureNoticeMarkdown); if
    # upstream ever reword that heading, the drift direction would be
    # fail-closed (a label event post-outage goes red), never vice
    # versa — acceptable and documented here.
    #
    # gh api --paginate --jq applies --jq PER PAGE and prints one
    # value per page; counts must be summed over pages (evaluating a
    # multi-line "0\n3" with [[ "$x" -gt 0 ]] is a silent bash
    # arithmetic failure — false — which is exactly the direction
    # this gate must never fail in).
    marker='<!-- ai-pr-review'
    notice='## AI review could not run'
    # Initial verdict snapshot with the same bounded tolerance the
    # poll loop below uses — a single API blip right after the
    # label burst must not become the (terminal) red conclusion.
    scan_ok=0
    for _ in $(seq $(( GATE_POLL_MAX_CONSEC_ERRORS + 1 ))); do
      if scan_reviews; then scan_ok=1; break; fi
    done
    [[ "$scan_ok" -eq 1 ]] || { echo "::error::could not read PR reviews"; exit 1; }
    if [[ "$blockers" -gt 0 ]]; then
      echo "::error::Open blocker findings published by the AI review at ${head_sha:0:8} — blocking automerge. Re-review via the 'ai-review' label or a rebase."
      exit 1
    fi
    if [[ "$reviewed" -gt 0 ]]; then
      echo "Review skipped and managed review at this head SHA is clean: gate passes."
      exit 0
    fi

    # ── Pre-verdict event (no managed review at this HEAD yet).
    # The `opened` review takes minutes while further events (e.g.
    # `ready_for_review` after a draft, or the labels workflow's own
    # concurrent hold flows) can land a gate run against a SHA that
    # has no verdict yet. Two hard constraints shape what can go
    # here:
    #   • Branch protection resolves a required check against the
    #     LAST run STARTED for the head SHA, not the last completed
    #     one. With no label events anymore the `opened`/`synchronize`
    #     run is normally last — but gate runs CAN still go red
    #     mid-flight before the verdict lands (infra failure, poll
    #     budget exhaustion). A terminal green must only ever come
    #     from a landed clean verdict.
    #   • A one-shot pass before any verdict exists is FAIL-OPEN:
    #     Renovate merges as soon as the required check turns green,
    #     and a later REQUEST_CHANGES, timeout, or infra failure can
    #     never turn the SHA red after the fact.
    # So wait — bounded — for the verdict that is already being
    # produced, then decide on the verdict itself. Green is only
    # ever published from a landed clean verdict; every other exit
    # stays fail-closed (self-healing via the `ai-review` label, a
    # rebase, or the next review event). The schedule remains
    # fail-open on a pure LLM outage upstream: a degraded "notice"
    # verdict publishes a managed review at this SHA, which reads
    # as clean here (as the blockers check above documents).
    if review_in_flight; then :; else
      rf="$?"
      if [[ "$rf" -gt 1 ]]; then
        # Initial count blipped: enter the poll, which tolerates a
        # bounded number of consecutive API errors before closing.
        echo "::warning::could not inspect in-flight review runs at ${head_sha:0:8}; entering bounded poll"
      else
        # Grace: the review run of the main workflow may exist but not
        # yet be registered in the Actions API if this gate was picked
        # up within seconds of PR creation. Give the registry one poll
        # interval, then re-check; only then fail closed.
        sleep "${GATE_POLL_INTERVAL_SEC}"
        if review_in_flight; then :; else
          rf2="$?"
          if [[ "$rf2" -le 1 ]]; then
            echo "::error::Review skipped with no managed AI review yet at ${head_sha:0:8} — blocking automerge until the first review lands."
            exit 1
          fi
          echo "::warning::could not inspect in-flight review runs at ${head_sha:0:8}; entering bounded poll"
        fi
      fi
    fi
    deadline=$(( $(date +%s) + GATE_POLL_BUDGET_SEC ))
    poll_errs=0
    while :; do
      sleep "${GATE_POLL_INTERVAL_SEC}"
      scan_ok=0
      if scan_reviews; then
        scan_ok=1
        poll_errs=0
      else
        poll_errs=$(( poll_errs + 1 ))
      fi
      if [[ "$scan_ok" -eq 1 ]]; then
        if [[ "$blockers" -gt 0 ]]; then
          echo "::error::Open blocker findings published by the AI review at ${head_sha:0:8} — blocking automerge. Re-review via the 'ai-review' label or a rebase."
          exit 1
        fi
        if [[ "$reviewed" -gt 0 ]]; then
          # This is the gate's SLOW pass path: a (possibly stale)
          # hold state must be re-read before publishing green —
          # see hold_present() above.
          hold="$(hold_present)" \
            || { echo "::error::could not re-evaluate PR labels for 'hold'"; exit 1; }
          if [[ "$hold" == "true" ]]; then
            echo "::error::'hold' label was added while the gate waited — merge is manually held. Remove the label to re-open the gate."
            exit 1
          fi
          echo "Managed review for ${head_sha:0:8} landed and is clean: gate passes."
          exit 0
        fi
      elif (( poll_errs > GATE_POLL_MAX_CONSEC_ERRORS )); then
        echo "::error::could not read PR reviews (repeatedly) while waiting at ${head_sha:0:8} — blocking automerge (fail-closed). Re-review via the 'ai-review' label or a rebase."
        exit 1
      fi
      # Transient API failures while counting in-flight runs just
      # keep polling — the budget bounds them in the fail-closed
      # direction. A drained flight (return 1) acts on fresh
      # evidence only (scan_ok), so a verdict that silently landed
      # behind a transient read error is not raced into red.
      review_in_flight
      rf="$?"
      if [[ "$rf" -eq 1 && "$scan_ok" -eq 1 ]]; then
        break
      fi
      if (( $(date +%s) >= deadline )); then
        echo "::error::Managed review at ${head_sha:0:8} did not land within the poll budget — blocking automerge (fail-closed). Re-review via the 'ai-review' label or a rebase."
        exit 1
      fi
    done
    echo "::error::Review skipped with no managed AI review yet at ${head_sha:0:8} — blocking automerge until the first review lands."
    exit 1
    ;;
  *)
    echo "::error::Unexpected review job result '$REVIEW_RESULT' — blocking automerge (fail-closed)."
    exit 1
    ;;
esac
