# Memini Single Renovate Dependency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse memini's two Renovate dependencies (core chart OCIRepository + openclaw plugin pins) into one docker dependency so every release update lands as a single atomic PR.

**Architecture:** The `MEMINI_PLUGIN_VERSION` pins in `mainclaw`/`devclaw` adopt the same `docker` depName as the core `OCIRepository` (`registry.erwanleboucher.dev/eleboucher/charts/memini`). Renovate merges the three matches into one dependency with three file locations. A POSIX `${VAR#v}` expansion strips the chart tag's `v` prefix for ClawHub.

**Tech Stack:** Flux (HelmRelease YAML), Renovate custom regex manager, `/bin/sh` startup scripts, `flate` (local kustomize/HelmRelease validator), `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-08-31-memini-renovate-single-dep-design.md`

## Global Constraints

- Work on existing branch `memini-renovate-single-dep` (already contains the design doc, commit `25a6cc9f0`). Do NOT create a new branch.
- Version pin stays `v0.7.22` everywhere in this PR — do NOT bump any version; Renovate will open the bump PR itself.
- `.clawver` content format stays stripped (`0.7.22`, no `v`).
- Do NOT touch: `.renovate/groups.json5`, `.renovate/customManagers.json5`, `kubernetes/apps/ai/memini/app/ocirepository.yaml`.
- Shell code must be POSIX sh (`${MEMINI_PLUGIN_VERSION#v}` is valid; no bashisms).
- The YAML block-scalar indentation is 16 spaces for script lines inside `command:` — preserve exactly.
- ClawHub always receives the stripped form (`0.7.22`), never `v0.7.22`.

---

### Task 1: Re-pin plugin version to the core docker dependency in mainclaw and devclaw

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/helmrelease.yaml:70-78`
- Modify: `kubernetes/apps/ai/devclaw/app/helmrelease.yaml:47-55`

**Interfaces:**
- Consumes: nothing (standalone config edit).
- Produces: three Renovate matches for one dependency — `datasource=docker`, `depName=registry.erwanleboucher.dev/eleboucher/charts/memini`, `currentValue=v0.7.22` — in `mainclaw/app/helmrelease.yaml`, `devclaw/app/helmrelease.yaml`, and `memini/app/ocirepository.yaml` (untouched, already matching). Later tasks and Renovate rely on this exact depName/currentValue pairing.

- [ ] **Step 1: Edit mainclaw helmrelease**

Use the Edit tool on `kubernetes/apps/ai/mainclaw/app/helmrelease.yaml` with exactly (16-space indentation on every line):

oldString:
```
                # renovate: datasource=github-tags depName=eleboucher/memini
                MEMINI_PLUGIN_VERSION=0.7.22
                if [ "$(cat "$HOME/.openclaw/extensions/memini/.clawver" 2>/dev/null)" != "$MEMINI_PLUGIN_VERSION" ]; then
                  if node dist/index.js plugins install "clawhub:@eleboucher/memini@$MEMINI_PLUGIN_VERSION" --pin --force; then
                    printf '%s' "$MEMINI_PLUGIN_VERSION" > "$HOME/.openclaw/extensions/memini/.clawver"
```

newString:
```
                # renovate: datasource=docker depName=registry.erwanleboucher.dev/eleboucher/charts/memini
                MEMINI_PLUGIN_VERSION=v0.7.22
                if [ "$(cat "$HOME/.openclaw/extensions/memini/.clawver" 2>/dev/null)" != "${MEMINI_PLUGIN_VERSION#v}" ]; then
                  if node dist/index.js plugins install "clawhub:@eleboucher/memini@${MEMINI_PLUGIN_VERSION#v}" --pin --force; then
                    printf '%s' "${MEMINI_PLUGIN_VERSION#v}" > "$HOME/.openclaw/extensions/memini/.clawver"
```

- [ ] **Step 2: Edit devclaw helmrelease**

Use the Edit tool on `kubernetes/apps/ai/devclaw/app/helmrelease.yaml` with exactly the same oldString/newString pair as Step 1 (the same 5 lines appear there at the same 16-space indentation; lines 47-51).

- [ ] **Step 3: Syntax-check both embedded scripts**

Run:
```bash
sed -n '70,78p' kubernetes/apps/ai/mainclaw/app/helmrelease.yaml | sh -n && echo MAINCLAW_SH_OK
sed -n '47,55p' kubernetes/apps/ai/devclaw/app/helmrelease.yaml | sh -n && echo DEVCLAW_SH_OK
```
Expected: `MAINCLAW_SH_OK` and `DEVCLAW_SH_OK`, exit code 0. Any `sh: syntax error` means the edit broke quoting — fix before continuing. (Line counts are unchanged by the edit, so ranges stay valid.)

- [ ] **Step 4: Validate HelmReleases with flate**

Per-app paths cannot resolve cross-tree `dependsOn` (e.g. kopiur in `kopiur-system`) — validate the whole tree:

Run:
```bash
mise exec -- flate test hr --path ./kubernetes/apps
```
Expected: exit code 0, all HelmReleases pass (includes mainclaw, devclaw, memini).

- [ ] **Step 5: Verify the single-dependency invariant**

Run:
```bash
rg -n "renovate: datasource" kubernetes/apps/ai/mainclaw/app/helmrelease.yaml kubernetes/apps/ai/devclaw/app/helmrelease.yaml
rg -n "MEMINI_PLUGIN_VERSION=" kubernetes/apps/ai/mainclaw/app/helmrelease.yaml kubernetes/apps/ai/devclaw/app/helmrelease.yaml
rg -n "depName=eleboucher/memini" kubernetes/ && echo "FAIL: stale github-tags dep" || echo "NO_STALE_DEP"
rg -c "v0\.7\.22" kubernetes/apps/ai/mainclaw/app/helmrelease.yaml kubernetes/apps/ai/devclaw/app/helmrelease.yaml kubernetes/apps/ai/memini/app/ocirepository.yaml
```
Expected:
1. Both files show `renovate: datasource=docker depName=registry.erwanleboucher.dev/eleboucher/charts/memini`.
2. Both files show `MEMINI_PLUGIN_VERSION=v0.7.22`.
3. `NO_STALE_DEP`.
4. `v0.7.22` count: 1 occurrence per file (3 files listed).

- [ ] **Step 6: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/helmrelease.yaml kubernetes/apps/ai/devclaw/app/helmrelease.yaml
git commit -m "refactor(deps): pin memini plugins to core chart dependency"
```

### Task 2: Full validation and PR

**Files:**
- Create: none (pushes Task 1's commits)

**Interfaces:**
- Consumes: Task 1's committed edits on branch `memini-renovate-single-dep`.
- Produces: pushed branch + pull request for human review.

- [ ] **Step 1: Full cluster validation**

Run:
```bash
mise exec -- flate test ks --path ./kubernetes/apps
```
Expected: exit code 0, no errors.

- [ ] **Step 2: Push and open the PR**

```bash
git push -u origin memini-renovate-single-dep
gh pr create --title "refactor(renovate): single memini dependency for core + plugin pins" --body "$(cat <<'EOF'
Single Renovate dependency for memini: core chart + openclaw plugin pins.

- Re-pin `MEMINI_PLUGIN_VERSION` in mainclaw/devclaw to the same docker depName as the core OCIRepository (`registry.erwanleboucher.dev/eleboucher/charts/memini`); drops the independent `github-tags depName=eleboucher/memini` dep
- `${MEMINI_PLUGIN_VERSION#v}` strips the chart tag prefix; `.clawver` format unchanged, so no redundant plugin reinstall on first boot
- Renovate now updates all three locations in one atomic PR, eliminating the plugins-only vs core-only PR race (#4072/#4074, #3994/#3996). PR #4114 was merged before this refactor; this PR makes the grouping race-proof
- Version stays at v0.7.22 here; Renovate opens the next bump PR under the new scheme

Design: docs/superpowers/specs/2026-08-31-memini-renovate-single-dep-design.md
EOF
)"
```
Expected: PR URL printed. Leave review/merge to the human.

- [ ] **Step 3: Sanity-check the pushed diff**

Run:
```bash
gh pr diff --patch | rg -c '^\+[^+]'
```
Expected output: `10` (5 replaced lines per file). `2` would mean only one file changed; anything else — re-inspect `gh pr diff` manually before asking for review.
