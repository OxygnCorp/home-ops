# phoenix-evals

Nightly CronJob that judges recent Phoenix traces with an LLM-as-judge
(`dsv41f` via litellm), publishes `quality` span annotations, and appends
failing traces to the `phoenix-evals-failures` regression dataset.

## How it runs

- Schedule: `2 3 * * *` Europe/Paris, `concurrencyPolicy: Forbid`.
- Reads the last `PHOENIX_EVALS_MAX_SPANS` (default 50) spans of project
  `PHOENIX_EVALS_PROJECT` (default `default`) sorted by `start_time` desc.
- For each span, calls litellm `/v1/chat/completions` (virtual key
  `KEY_PHOENIX_EVALS`, alias `Phoenix-Evals`) and parses a strict JSON
  `{"score", "reason"}`.
- Posts span annotations (`annotator_kind: LLM`, `name: quality`) with
  `result: {label, score, explanation}` and `identifier: phoenix-evals`
  (idempotent upsert on re-run).
- Traces scoring below `PHOENIX_EVALS_THRESHOLD` (default 0.5) are appended
  to dataset `phoenix-evals-failures` via `/v1/datasets/upload?sync=true`
  (`action: create` if absent, `action: append` otherwise — never recreated).

The judge's own litellm calls are traced in Phoenix under key alias
`Phoenix-Evals`, so the cost of LLM-as-judge is observable.

## Daily workflow

1. CronJob runs nightly; inspect runs via
   `kubectl logs -n observability job/<name>` or the failed-job history
   (Prometheus rule `PhoenixEvalsJobFailed`).
2. In the Phoenix UI, review `quality` annotations on recent traces; relabel
   in the UI when the judge is wrong (human overrides stay alongside LLM
   annotations thanks to distinct `identifier`).
3. The `phoenix-evals-failures` dataset grows incrementally — use it as the
   regression set for prompt/model changes: run a Phoenix experiment against
   it before merging a change, compare scores to the `baseline` tag.

## Forcing a run

```bash
kubectl create job -n observability --from=cronjob/phoenix-evals phoenix-evals-manual
kubectl logs -n observability job/phoenix-evals-manual
kubectl delete job -n observability phoenix-evals-manual
```

## Secrets

- `phoenix-evals` Secret: `PHOENIX_SYSTEM_API_KEY` (from 1Password item
  `phoenix`), `LITELLM_API_KEY` (virtual key `KEY_PHOENIX_EVALS`).
- Stays in `SecretSyncedError` until `PHOENIX_SYSTEM_API_KEY` exists in the
  `phoenix` 1Password item (created post-deploy in Phoenix UI) — expected.

## Smoke test (post-merge, deferred)

Step 11 of the task brief (forced run + UI verification of annotations and
dataset rows) is deferred to post-merge since it requires a live cluster.
