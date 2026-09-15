# foreman

Agentic coding pipeline on [LLMKube Foreman](https://llmkube.com/docs/foreman), adapted
from joryirving/home-ops in two deliberately lighter phases: the operator + agents
(phase 1), then a label watcher for autonomous dispatch (phase 2). No Dispatch and no
bridge — GitHub labels play the role of lanes.

Chart: `oci://ghcr.io/defilantech/charts/foreman` (Renovate-managed, aligned with the
installed llmkube core chart version — `dependsOn: llmkube`).

## Structure (three Flux Kustomizations)

```
ai/foreman            → app/       operator + CRDs (Workload, AgenticTask, Agent, FleetNode)
ai/foreman-agents     → agents/    Agent CRs (dependsOn: foreman, wait: true)
ai/foreman-watcher    → watcher/   label-watcher CronJob (dependsOn: foreman-agents)
```

`foreman-agents` is a separate Kustomization **because of CRD ordering**: the chart
installs the CRDs, and kustomize would otherwise apply the `Agent` CRs in the same pass
as the HelmRelease — failing dry-run with `no matches for kind "Agent"`.

## Agents

| Agent | Model | Where it runs |
|---|---|---|
| `coder` | `go-glm-5.3-flash` | `execution.mode: Job` — ephemeral pod, survives operator restarts, no FleetNode reservation (LLMKube#1496). Polyglot image `misospace/llmkube-coder` (Python/Node/Go baked in, rootless can't install anything at runtime) |
| `coder-escalation` | `dsv41f-max` | Same, used only on failed-workload retries |
| `reviewer` | `dsv41f` | in-process in the `foreman-agent` pod; read-only tool whitelist (no write_file/str_replace), bounded by prompt instruction |

Model selection is grounded in the LMArena Agent Arena board (tool orchestration,
confirmed-success, bash recovery — the signals that matter for the foreman loop):
`deepseek-v4.1-flash` ranks #12 with 13.75% confirmed success at $0.06/task, which is
why the escalation tier uses it rather than DeepSeek V4 Pro (#15) or GPT 5.6 Luna (#25,
~0% net improvement — a volume tier, not an agent). Kimi K3 (#8, 14.8%) is the
recorded fallback if escalation underperforms.

`dsv41f-max` is a litellm route identical to `dsv41f` with `reasoning_effort: max`
pinned in `params.additional` — the foreman agent loop sends no per-request reasoning
param, so the route force-applies it. OpenCode Go exposes a single model id but honours
the param (probe-tested: `max` accepted, `none` disables reasoning, litellm passes it
through verbatim).

## End-to-end flow

```
GitHub issue labeled foreman/ready
    │  watcher CronJob */15 (Europe/Paris)
    ▼
Workload wx-<n> ──► code   coder Agent (Job): fetch_issue → edit → verify → push
    │                           foreman/wx-<n>/issue-<n>
    └─► review reviewer Agent: diff vs issue, verbatim quote rail, PR-body grounding
    ▼ review GO
foreman opens the PR (Fixes #<n>)   → CI / konflate / AI PR review → human merge
    ▼ next watcher pass
issue comment with the PR link + label dropped + Workload CR reaped
```

Dispatch options:

- **Automatic**: label the issue `foreman/ready`. The watcher caps concurrency at
  `MAX_IN_PROGRESS=2` in-flight workloads.
- **Manual**: `just foreman-work <issue-number> <name>` (recipe in
  `kubernetes/mod.just`, intent built from the issue title).

The **Workload CRs are the state** — nothing is stored on disk, and a Workload only
exists while the pipeline runs or until its outcome is reported back to the issue.

## Watcher semantics (attempt lifecycle)

| Workload state on sweep | Action |
|---|---|
| In flight | skipped, counted toward the cap |
| Completed + open PR on branch | issue comment, label dropped, CR deleted |
| Completed, no PR (e.g. `ALREADY-RESOLVED`) | comment, label dropped, CR deleted |
| Failed, attempt < `MAX_ATTEMPTS` (2) | remote branch cleared, CR recreated as attempt N+1; final attempt escalates to `coder-escalation` |
| Failed at `MAX_ATTEMPTS` | human-triage comment (partial work may be on the branch), label dropped |

GitHub label cleanup and comments degrade gracefully: a PAT lacking `issues:write`
only costs the reporting, the pipeline keeps working.

## Issue contract

The reviewer's deterministic rails quote the issue verbatim (`issueAsk`), so an issue
that satisfies neither the quote rail nor the file-path scope vouch gets correct work
rejected. Every issue should carry one imperative sentence stating the ask plus the
concrete file paths the fix is expected to touch.

## Security

- Fine-grained PAT (1Password item `foreman`, user `puchu-ai`): `contents:read+write`
  and `pull_requests:read+write` **on `OxygnCorp/home-ops` only** — branch pushes +
  PR opening; plus `issues:read+write` for the watcher's label/comment reporting.
- **PRs are never auto-merged.** konflate + AI PR review + human merge are unchanged
  for bot PRs.
- Known trade-off (same as upstream): the coder Job mounts the credentials secret.

## Operations

- **Retry an issue**: delete the workload (`kubectl delete workload <name> -n ai`) and
  the remote branch — the harness cannot force-push, so a surviving branch rejects the
  retry's push (non-fast-forward). The watcher does this automatically; manual dispatch
  does not.
- **Rotate the `foreman` PAT**: annotate
  `kubectl annotate externalsecret foreman-watcher -n ai force-sync=$(date +%s)`
  (watcher Jobs read the secret fresh each run) **and**
  `kubectl rollout restart deploy/foreman-default-agent -n ai` — the in-process
  reviewer holds its token since pod start, stale-token PR calls fail with 401.
- **Watch the pipeline**: `kubectl get workload,agentictask -n ai -w`; coder Jobs log
  a `FOREMAN-RESULT` line; transcripts land in `foreman-transcript-<workload>` ConfigMaps.
- **Force a sweep**: `kubectl create job --from=cronjob/foreman-watcher <name> -n ai`.

## Lessons (each earned by an incident)

- **CRD ordering**: Agent CRs must not share a Kustomization with the operator's
  HelmRelease → the three-KS split above with `wait: true`.
- **Label names in API paths**: GitHub label containing `/` must be URL-encoded
  (`foreman%2Fready`) or actions silently target the wrong path.
- **Branches survive their workload**: always clear `foreman/*` branches on retry;
  a divergent second push fails fast-forward and the coder reports `PUSH-FAILED`.
- **In-process agents cache credentials at pod start**; only Job-mode tasks re-read.
- Reviewer "text without tool_calls" (`INCOMPLETE` verdicts) is the model drift
  failure mode to watch — retrying is reasonable, swapping the model is the fix.

## Not deployed (deliberate)

Pr-fix loop (CI-red → auto-amend), Dispatch issue-grooming, lanes and retry- storms /
gate profile maps. Revisit when issue volume justifies it — the Dispatch stack is one
HelmRelease + CNPG + OIDC away in the upstream layout.
