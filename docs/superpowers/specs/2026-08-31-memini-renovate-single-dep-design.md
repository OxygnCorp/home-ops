# Memini: Single Renovate Dependency (Core + Plugins in Lockstep)

- **Date:** 2026-08-31
- **Status:** Approved design (pre-implementation)
- **Scope:** `kubernetes/apps/ai/{mainclaw,devclaw}/app/helmrelease.yaml`, `.renovate/groups.json5` (unchanged, kept as-is)

## Problem

Memini reaches the cluster through two kinds of artifacts that upstream publishes from the
same release:

| Artifact | Consumed by | Renovate dep today |
|---|---|---|
| OCI Helm chart `registry.erwanleboucher.dev/eleboucher/charts/memini` | `OCIRepository` in `kubernetes/apps/ai/memini/app/ocirepository.yaml` (the **core**) | `docker` (flux manager) |
| ClawHub plugin `@eleboucher/memini` | startup script of `mainclaw` + `devclaw` (the **plugins**) | `github-tags` (custom regex manager) |

Upstream publishes the GitHub release (plugin) **before** the OCI chart. Renovate can only
group updates discovered in the **same run**, so when a run lands in the publication gap the
update splits into two PRs:

- 2026-08-28: PR #4072 (plugins-only, merged) + PR #4074 (core-only, manually closed)
- 2026-08-22: PR #3994 + PR #3996, opened 15 minutes apart
- 2026-08-31 (PR #4114): grouped correctly — the race only bites intermittently

No Renovate mechanism ("wait for sibling dependency") can close this gap;
`minimumReleaseAge` delays each update independently and does not shrink the race window.

Because plugin and core are the same upstream version, they must move in lockstep; a PR that
bumps one without the other is both a review burden and a drift risk.

## Chosen Approach

**Collapse the two Renovate dependencies into one.** The plugin pins in `mainclaw` and
`devclaw` adopt the same `docker` depName as the core `OCIRepository`
(`registry.erwanleboucher.dev/eleboucher/charts/memini`). Renovate then tracks a single
dependency with three file locations and updates all of them in one branch/commit — no
grouping involved, no race possible by construction.

The dependency only materializes once the chart tag is visible in the registry, i.e. the
**last-published artifact gates the whole update**. The plugin (ClawHub) is published with or
before the release, so it is installable by the time the PR opens.

Rejected alternatives:

- **Flux vars single-source:** plugin versions would be read from the in-cluster
  `OCIRepository` via `Kustomization.spec.vars`. Rejected: depends on `fieldPath` support
  against `spec.ref.tag`, downstream re-render is delayed by the 1h reconcile interval, and it
  introduces cluster-state coupling into what is today a purely git-state flow.
- **Status quo / cosmetic grouping tweaks:** keeps the race; contradicts the goal.

## Changes

### 1. `mainclaw` and `devclaw` startup script (identical edit in both `helmrelease.yaml`)

Before:

```sh
# renovate: datasource=github-tags depName=eleboucher/memini
MEMINI_PLUGIN_VERSION=0.7.21
if [ "$(cat "$HOME/.openclaw/extensions/memini/.clawver" 2>/dev/null)" != "$MEMINI_PLUGIN_VERSION" ]; then
  if node dist/index.js plugins install "clawhub:@eleboucher/memini@$MEMINI_PLUGIN_VERSION" --pin --force; then
    printf '%s' "$MEMINI_PLUGIN_VERSION" > "$HOME/.openclaw/extensions/memini/.clawver"
  else
    echo "WARN: memini plugin install failed; starting with whatever is present"
  fi
fi
```

After:

```sh
# renovate: datasource=docker depName=registry.erwanleboucher.dev/eleboucher/charts/memini
MEMINI_PLUGIN_VERSION=v0.7.21
# Strip the chart tag prefix at runtime; braced shell expansion does not survive
# the Flux postBuild variable substitution
MEMINI_PLUGIN_REL=$(printf '%s' "$MEMINI_PLUGIN_VERSION" | sed 's/^v//')
if [ "$(cat "$HOME/.openclaw/extensions/memini/.clawver" 2>/dev/null)" != "$MEMINI_PLUGIN_REL" ]; then
  if node dist/index.js plugins install "clawhub:@eleboucher/memini@$MEMINI_PLUGIN_REL" --pin --force; then
    printf '%s' "$MEMINI_PLUGIN_REL" > "$HOME/.openclaw/extensions/memini/.clawver"
  else
    echo "WARN: memini plugin install failed; starting with whatever is present"
  fi
fi
```

Notes:

- The stripped form is derived at runtime through unbraced shell variables only
  (`$MEMINI_PLUGIN_VERSION`, `$MEMINI_PLUGIN_REL`). The Flux `Kustomization`
  `postBuild.substitute` pass defined in each app's `ks.yaml` (envsubst-style) replaces
  braced `${...}` references with the value of that name — empty for unknown names — so an
  earlier draft using a braced strip rendered to an empty string in konflate's diff.
  Unbraced references to undefined variables survive the substitution (`$HOME` proves it
  in production).
- ClawHub keeps receiving the stripped form (`0.7.21`), and `.clawver` keeps storing the
  stripped form, so existing installs do not trigger a redundant reinstall on first boot
  after this change.
- The custom regex manager in `.renovate/customManagers.json5` ("Process annotated
  dependencies") extracts `datasource=docker`,
  `depName=registry.erwanleboucher.dev/eleboucher/charts/memini`, `currentValue=v0.7.21`,
  which is byte-identical to the flux manager's extraction of the `OCIRepository` — Renovate
  merges them into one dependency.

### 2. `.renovate/groups.json5` — no change

The `memini` group keeps matching `/charts/memini$/` (the single remaining dep). The
`/eleboucher/memini$/` pattern stays: it matches nothing after this change, is harmless, and
defends against reintroducing a similarly named dep later.

## Transition / Rollout

> **Superseded note (2026-08-31):** Renovate PR #4114 merged before implementation began; the branch was rebased on the v0.7.22 baseline and the steps below describe the original (pre-merge) sequence.

1. Implement the refactor on the current `main` state (pin stays `v0.7.21`).
2. Merge via PR. Open PR #4114 becomes obsolete: its `github-tags` dep no longer exists on
   main, so Renovate closes it automatically.
3. Renovate's next run sees the docker dep at `v0.7.21` with `v0.7.22` available and opens a
   **new** memini PR under the new scheme, touching all three files. Old-format `.clawver`
   content is unaffected.

## Validation

- `flate test hr --path ./kubernetes/apps/ai/mainclaw` and same for `devclaw`, `memini`.
- `sh -n` on the extracted startup script to catch shell syntax errors.
- Visual check of the final rendered files: annotation depName, `v` prefix handling, and the
  three locations staying byte-consistent (`v0.7.x` everywhere Renovate writes, stripped
  form only inside clawhub calls / `.clawver`).
- Rendered Flux output: `flux build kustomization mainclaw --namespace ai --path
  <worktree>/kubernetes/apps/ai/mainclaw/app` (and `devclaw`) must keep the assignment line
  `MEMINI_PLUGIN_REL=$(printf '%s' "$MEMINI_PLUGIN_VERSION" | sed 's/^v//')` intact and show
  `clawhub:@eleboucher/memini@$MEMINI_PLUGIN_REL` — the gate that catches postBuild
  substitution damage, invisible to schema-only checks (`flate`).

## Risks

- **Upstream format change:** if a future chart tag ever stops sharing the plugin version
  scheme, the single dep would bump them together anyway — the version-guard + WARN in the
  startup script degrades gracefully (old plugin keeps running).
- **ClawHub lag:** if ClawHub is slower than the chart registry for a given release, the pod
  rolls with the new core but the plugin install fails once at startup (WARN, old plugin
  retained) until the next restart. Same failure mode exists today; no regression.
