# mainclaw: mise-managed CLI tools (op, gh) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `op` (1Password CLI) and `gh` (GitHub CLI) reliably available inside the mainclaw openclaw container by declaring them in a GitOps-managed mise config and installing them on the PVC via an initContainer.

**Architecture:** A ConfigMap holds a mise `config.toml` declaring the tool versions. It is mounted read-only over `~/.config/mise/config.toml` (shadowing a stale PVC-local copy). A new `install-tools` initContainer (openclaw image, which has curl — alpine does not) runs `mise install`, which is idempotent and offline when versions already match. Binaries land in `.local/share/mise/`, which is already excluded from kopia snapshots.

**Tech Stack:** Flux / bjw-s app-template HelmRelease, mise, kustomize, flate (local validation)

## Global Constraints

- Repo: `/home/nea0d/git/home-ops`, branch `feat/mainclaw-mise-tools` (already created, spec already committed)
- App dir: `kubernetes/apps/ai/mainclaw/app/`
- `metadata.namespace` is never set inline on resources (kustomize injects it) — per AGENTS.md
- No unit tests in this repo — the test cycle is `mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw` (must pass) plus `flate diff` vs main before the PR
- Versions (verified 2026-08-28): `op = "2.39.0"` (latest stable on AgileBits feed), `gh = "2.98.0"` (latest via `mise ls-remote gh`)
- Renovate will NOT auto-bump these (its regex manager captures the TOML quotes; the mise manager doesn't parse YAML-wrapped ConfigMaps) — bumps are manual one-line edits. Do not add `# renovate:` annotations to the TOML.
- Every commit message follows repo style: `feat(scope): ...` / `fix(scope): ...` (lowercase, conventional)

## Empirical facts (validated on the live pod — do not re-litigate)

1. `MISE_YES=1 mise install` with a `[tools]` config downloads from `cache.agilebits.com` in-cluster (egress OK), checksum-verifies, installs to `/home/node/.local/share/mise/installs/`.
2. mise shims auto-install missing versions based on the **global config file**: if `~/.config/mise/config.toml` on the PVC is stale (`op = "2.34.1"`), the shim silently installs 2.34.1. Shadowing that file with the ConfigMap mount is therefore mandatory, not optional.
3. Stock `docker.io/library/alpine` has no `curl` — the mise-install step currently in the alpine `init` container can never work on a fresh PVC.
4. The openclaw image (`ghcr.io/openclaw/openclaw` @ `2026.7.1@sha256:6a31d44b...`) is Debian bookworm with `/usr/bin/curl`, `/usr/bin/tar`, `/usr/bin/git`. mise is a static binary and needs none of them for installs.
5. A `/tmp/mise-test.toml` and an op 2.34.1 install were left on the pod during investigation — Task 3 cleans up.

---

### Task 1: ConfigMap `mainclaw-mise`

**Files:**
- Create: `kubernetes/apps/ai/mainclaw/app/mise.yaml`
- Modify: `kubernetes/apps/ai/mainclaw/app/kustomization.yaml` (add `- ./mise.yaml`)

**Interfaces:**
- Produces: ConfigMap named `mainclaw-mise` with key `config.toml` (valid TOML: `[tools]` table). Task 2 references this name/key via `persistence.mise-config`.

- [ ] **Step 1: Create `mise.yaml`**

Follows the inline-ConfigMap precedent of `kubernetes/apps/ai/mainclaw/app/kopiaignore.yaml`:

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: mainclaw-mise
data:
  config.toml: |
    # Tools installed on the PVC by the install-tools initContainer.
    # Binaries live in .local/share/mise/ (excluded from kopia snapshots,
    # restorable via `mise install`). Bump versions manually.
    [tools]
    op = "2.39.0"
    gh = "2.98.0"
```

- [ ] **Step 2: Register in `kustomization.yaml`**

Add `- ./mise.yaml` to `resources:` (after `- ./kustomization.yaml`'s existing entries, matching current order style):

```yaml
resources:
  - ./ocirepository.yaml
  - ./helmrelease.yaml
  - ./externalsecret.yaml
  - ./kopiaignore.yaml
  - ./mise.yaml
```

- [ ] **Step 3: Validate**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw`
Expected: pass (HelmRelease still renders; ConfigMap manifests are also schema-checked)

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/mise.yaml kubernetes/apps/ai/mainclaw/app/kustomization.yaml
git commit -m "feat(mainclaw): add mise tools configmap for op and gh"
```

---

### Task 2: HelmRelease wiring (install-tools initContainer + config shadow mount)

**Files:**
- Modify: `kubernetes/apps/ai/mainclaw/app/helmrelease.yaml` (initContainers block ~lines 18-39, persistence block ~lines 148-178)

**Interfaces:**
- Consumes: ConfigMap `mainclaw-mise` key `config.toml` from Task 1.
- Produces: initContainer `install-tools` (runs after `init` — app-template renders initContainers in alphabetical key order: `init` < `install-tools`); volume mounted at `/home/node/.config/mise/config.toml` in all containers.

- [ ] **Step 1: Replace the alpine `init` command**

Remove the broken mise/curl block (alpine has no curl) and add the mount-point parent dir creation. New `initContainers:` block (this replaces `init` entirely and adds `install-tools` — reuse the exact openclaw image digest from the `app` container, keep `init` first):

```yaml
        initContainers:
          init:
            image:
              repository: docker.io/library/alpine
              tag: "3.24"
            command:
              - sh
              - -c
              - |
                set -euo pipefail
                mkdir -p /home/node/.openclaw
                rm -f /home/node/.openclaw/openclaw.json
                cp /tmp/openclaw.json /home/node/.openclaw/openclaw.json
                chown 1000:100 /home/node/.openclaw/openclaw.json
                chmod 400 /home/node/.openclaw/openclaw.json
                cp /kopiaignore/.kopiaignore /home/node/.kopiaignore
                # Parent dir for the mise config subPath mount (install-tools needs it)
                mkdir -p /home/node/.config/mise
          install-tools:
            image:
              repository: ghcr.io/openclaw/openclaw
              tag: 2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c
            env:
              HOME: /home/node
              PATH: /home/node/.local/bin:/home/node/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
              MISE_YES: "1"
            command:
              - /bin/sh
              - -c
              - |
                set -euo pipefail
                # Reinstall mise after a PVC restore; skip when present (normal restarts stay offline)
                if [ ! -f /home/node/.local/bin/mise ]; then
                  echo "Installing Mise..."
                  curl -fsSL https://mise.run | MISE_INSTALL_PATH=/home/node/.local/bin/mise sh
                fi
                # Install every tool declared in the shadowed global config; idempotent
                mise install
```

- [ ] **Step 2: Add the `mise-config` persistence entry**

Inside `persistence:` (after `openclaw-config:`), mount the ConfigMap over the stale PVC file in all containers:

```yaml
      mise-config:
        type: configMap
        name: mainclaw-mise
        globalMounts:
          - path: /home/node/.config/mise/config.toml
            subPath: config.toml
```

- [ ] **Step 3: Validate**

Run: `mise exec -- flate test hr --path ./kubernetes/apps/ai/mainclaw`
Expected: pass

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/ai/mainclaw/app/helmrelease.yaml
git commit -m "feat(mainclaw): install op and gh via mise in install-tools initcontainer"
```

---

### Task 3: Diff vs main, live-pod cleanup, PR

**Files:** none modified (verification + hygiene + PR)

**Interfaces:**
- Consumes: Tasks 1-2 committed on `feat/mainclaw-mise-tools`.

- [ ] **Step 1: Diff against main baseline**

```bash
git worktree add --detach /tmp/baseline origin/main
mise exec -- flate diff hr --path ./kubernetes/apps/ai/mainclaw --path-orig /tmp/baseline/kubernetes/apps/ai/mainclaw
git worktree remove /tmp/baseline --force
```

Expected: only the mainclaw HelmRelease diff (initContainers + persistence) and the new ConfigMap.

- [ ] **Step 2: Clean up investigation leftovers on the live pod**

```bash
kubectl exec -n ai deploy/mainclaw -c app -- rm -f /tmp/mise-test.toml
kubectl exec -n ai deploy/mainclaw -c app -- sh -c 'export PATH=/home/node/.local/bin:$PATH; mise rm op@2.34.1 2>/dev/null || true'
```

Expected: no error (the stale 2.34.1 install is removed from the store; 2.39.0 stays).

- [ ] **Step 3: Push and open PR**

```bash
git push -u origin feat/mainclaw-mise-tools
```

Open PR via `gh` targeting `main`, body summarizing the spec (`docs/superpowers/specs/2026-08-28-mainclaw-mise-tools-design.md`) and the post-merge verification steps below.

- [ ] **Step 4: Post-merge verification (run after Flux reconciles)**

```bash
kubectl rollout status -n ai deployment/mainclaw --timeout=5m
kubectl exec -n ai deploy/mainclaw -c app -- op --version   # expect: 2.39.0
kubectl exec -n ai deploy/mainclaw -c app -- gh --version   # expect: gh version 2.98.0
```

Then restart the pod once (`kubectl rollout restart -n ai deployment/mainclaw`) and confirm the `install-tools` init completes without network downloads (fast path).
