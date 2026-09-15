# foreman

Phase 1 of the LLMKube Foreman agentic pipeline (adapted from joryirving/home-ops):
the operator, two `Agent` CRs (coder + reviewer), and **manually created Workloads**.
No Dispatch, no bridge, no pr-fix loop — those are a possible phase 2 (a lightweight
label-watcher CronJob instead of the full Dispatch stack).

Chart: `oci://ghcr.io/defilantech/charts/foreman` pinned `0.9.25`, matching the
installed llmkube core chart version (`dependsOn: llmkube`).

## What is deployed

| Component | Notes |
|---|---|
| `foreman` HelmRelease | Operator + CRDs (`Workload`, `AgenticTask`, `Agent`, `FleetNode`) + default agent pool (replicaCount 1, roles worker/coder/reviewer) |
| `Agent/coder` | `go-glm-5.3-flash` via litellm, `execution.mode: Job` (survives operator restarts, no FleetNode reservation), polyglot image `misospace/llmkube-coder:0.9.25` |
| `Agent/reviewer` | `dsv41f` via litellm, read-only tool whitelist, in-process (runs in the foreman-agent pod) |
| `gateCache` | **disabled** — no gate/verifier Agent; repo CI + AI PR review are the verification backstops |

No `FleetNode` and no `Workload` is committed here: FleetNodes self-register at
runtime, and Workloads are created per issue (see below) — ephemeral runtime state.

## Running an issue through the pipeline

1. File/label the GitHub issue on `OxygnCorp/home-ops` (a clear imperative ask plus
   expected file paths — the reviewer's deterministic rails quote the issue verbatim).
2. Apply a Workload (template — `kubectl apply -f` it, or make a `just` recipe later):

   ```yaml
   apiVersion: foreman.llmkube.dev/v1alpha1
   kind: Workload
   metadata:
     name: fix-<issue>-<slug>
     namespace: ai
   spec:
     intent: "<one-sentence summary of the ask>"
     repo: OxygnCorp/home-ops
     issues: [<issue number>]
     coderAgentRef:
       name: coder
     reviewerAgentRefs:
       - name: reviewer
   ```

3. Watch it run: `kubectl get workload,agentictask -n ai -w`
4. On review GO, foreman opens a PR (`Fixes #<n>`) from branch
   `foreman/<workload>/issue-<n>` — konflate + AI PR review + human merge, as usual.

## Semantics

- **Retry**: delete the Workload and re-apply it (`kubectl delete workload <name> -n ai`).
  There is no automatic retry in phase 1 — deliberate, so every backend minute maps to
  a human-initiated action.
- **Dead ends**: the coder reports `DESIGN-DECISION`, `NO-TECHNICAL-FIX`,
  `BUDGET-EXHAUSTED` or `ALREADY-RESOLVED` in the Workload status/summary.
- **PRs are never auto-merged.** The token is a fine-grained PAT scoped to
  `contents:read+write` on `OxygnCorp/home-ops` only (1Password item `foreman`).

## Phase 2 — the label watcher (`../watcher/`)

The `foreman-watcher` CronJob (own Flux Kustomization `ai/foreman-watcher`,
`dependsOn: foreman-agents`) runs every 15 min:

- GitHub issues labeled **`foreman/ready`** (open, non-PR) → `Workload/wx-<n>` CRs
- Concurrency capped by `MAX_IN_PROGRESS` (in-flight Workloads)
- The **Workload CRs are the state** — nothing is stored on disk:
  - in flight → skipped and counted toward the cap
  - Completed + open PR on the branch → comment with the PR link,
    label dropped, Workload CR deleted (re-labeling re-dispatches cleanly)
  - Failed with `attempt < MAX_ATTEMPTS` → remote branch cleared (the harness
    cannot force-push), Workload recreated on attempt N+1; the final attempt
    runs `coder-escalation` (`dsv41f` with reasoning effort pinned to `max`
    via the `dsv41f-max` litellm route)
  - Failed at `MAX_ATTEMPTS` → comment for human triage, label dropped
- Label cleanup and comments are best-effort: the PAT must have
  **issues:read+write** for them (add "Issues: Read and write" to the
  1Password item `foreman`); without it the pipeline still works, only the
  issue reporting degrades.
- After rotating the `foreman` PAT: restart `deploy/foreman-default-agent`
  (the in-process reviewer holds the token since pod start) — the watcher and
  coder Jobs read the secret fresh each run.
