# AI PR Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Porter le workflow AI PR Review de joryirving/home-ops (reviewer AI basé sur `misospace/pr-reviewer-action`) adapté à notre infra : LiteLLM/SearXNG internes, konflate public, app GitHub konflate partagée, runner ARC in-cluster.

**Architecture:** Un workflow GitHub Actions tourne sur le runner auto-hébergé `home-ops-runner` (in-cluster → accès aux routes internes). Il génère un token via l'app GitHub konflate partagée, puis invoque `misospace/pr-reviewer-action` qui collecte le contexte (diff, CI, issues, evidence providers déterministes, tools MCP/web), classifie le PR, route vers primary/smart/fallback modèles via LiteLLM, et publie une review native advisory. Les evidence providers injectent le diff Flux rendu (konflate MCP) et les release notes amont + drift des values Helm.

**Tech Stack:** GitHub Actions (runner ARC), `misospace/pr-reviewer-action@v2.2.1`, Python 3 (stdlib pour konflate_evidence, PyYAML optionnel pour upgrade_impact), LiteLLM, konflate MCP, SearXNG.

**Spec:** `docs/superpowers/specs/2026-08-30-ai-pr-review-design.md` — approuvée.

## Global Constraints

- Branche de travail : `add-ai-pr-review` (déjà créée, spec commitée). Merge par PR uniquement.
- Actions pinées par SHA (copies verbatim) :
  - `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` # v7.0.1
  - `actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1` # v3.2.0
  - `misospace/pr-reviewer-action@54dfb1aac20e1e410ad8f71dc3681b888500a1ec` # v2.2.1
- URLs : `https://konflate.oxygn.dev/mcp` (MCP), `https://search.oxygn.dev/search` (SearXNG), `https://litellm.oxygn.dev/v1` (LiteLLM).
- Secrets GitHub : `APP_CLIENT_ID`, `APP_PRIVATE_KEY`, `LITELLM_API_KEY`. Vars : `LITELLM_URL`, `PRIMARY_MODEL` (`dsv4f`), `SMART_MODEL` (`zai-glm-5.2`), `FALLBACK_MODEL` (`MiniMax-M3`). Formats API tous `openai`, hardcoded.
- `runs-on: home-ops-runner`, `publish_mode: review_comment`, `inline_findings: "true"` — advisory, jamais de gate.
- `ai_max_tokens: "16000"` (≤ limite output de dsv4f : 16384).
- Les scripts evidence providers sont advisory-only : toute erreur → `{"severity": "info", "findings": []}` + exit 0.
- Aucun secret en clair dans les fichiers. Le client ID `Iv23lizpdaSYJBX0uzo8` est une donnée publique (déjà inline dans `kubernetes/apps/flux-system/konflate/app/helmrelease.yaml:24`).

---

### Task 1: Evidence providers (scripts Python + JSON)

**Files:**
- Create: `.github/scripts/konflate_evidence.py`
- Create: `.github/scripts/upgrade_impact_evidence.py`
- Create: `.github/konflate-evidence-providers.json`

**Interfaces:**
- Produces: deux commandes `python3 .github/scripts/<name>.py` lisant `PR_NUMBER` (env, fourni par l'action) et écrivant sur stdout le contrat JSON `{"severity": "info", "findings": [{"severity","message","source"}]}`, exit 0 toujours.
- Consumes (Task 3): le workflow référence `.github/konflate-evidence-providers.json` via `evidence_providers_file`, et `KONFLATE_MCP_URL` env.

- [ ] **Step 1: Créer `.github/scripts/konflate_evidence.py`**

Portage verbatim de jory avec 2 adaptations : URL par défaut → `https://konflate.oxygn.dev/mcp`, et `src` → `https://konflate.oxygn.dev/#/pr/{PR}`.

```python
#!/usr/bin/env python3
"""Evidence provider: konflate rendered-diff for the PR under review.

Emits the action's evidence-provider JSON contract on stdout:
  {"severity": "info", "findings": [{"severity","message","source"}]}

Reads PR_NUMBER from the environment (set by the action). Targets konflate's
read-only MCP endpoint (KONFLATE_MCP_URL). Read-only, advisory, never a gate:
on any failure or an untracked PR it emits an empty findings list and exits 0
so it can never block a review.
"""
import json, os, sys, urllib.error, urllib.request

URL = os.environ.get("KONFLATE_MCP_URL", "https://konflate.oxygn.dev/mcp")
PR = os.environ.get("PR_NUMBER", "").strip()
SID = None

def _emit(findings, severity="info"):
    print(json.dumps({"severity": severity, "findings": findings}))
    sys.exit(0)

def call(method, params=None, notif=False):
    global SID
    body = {"jsonrpc": "2.0", "method": method}
    if not notif:
        body["id"] = 1
    if params is not None:
        body["params"] = params
    req = urllib.request.Request(URL, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    # An explicit User-Agent is required: urllib's default ("Python-urllib/x")
    # trips Cloudflare's Browser Integrity Check (Error 1010, HTTP 403) at the
    # edge, even when the hostname is WAF-allowlisted. Any real UA passes.
    req.add_header("User-Agent", "ai-pr-reviewer-konflate/1.0")
    tok = os.environ.get("KONFLATE_MCP_TOKEN", "").strip()
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    if SID:
        req.add_header("Mcp-Session-Id", SID)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            sid = r.headers.get("Mcp-Session-Id")
            if sid:
                SID = sid
            raw = r.read().decode()
    except urllib.error.HTTPError as e:
        # Surface the edge/app body (e.g. a Cloudflare error page) so a future
        # block explains itself instead of a bare "HTTP Error 403".
        detail = e.read().decode("utf-8", "replace")[:200].replace("\n", " ")
        raise RuntimeError(f"HTTP {e.code} from {URL}: {detail}") from None
    if notif:
        return None
    for line in raw.splitlines():
        if line.startswith("data:"):
            return json.loads(line[5:].strip())
    return None

def _text(resp):
    out = []
    for c in (resp or {}).get("result", {}).get("content", []):
        if c.get("type") == "text":
            out.append(c["text"])
    return "\n".join(out).strip()

def main():
    if not PR.isdigit():
        _emit([])  # no PR context — nothing to add
    try:
        call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                            "clientInfo": {"name": "konflate-evidence", "version": "0"}})
        call("notifications/initialized", notif=True)
        summary = _text(call("tools/call", {"name": "get_pr_summary", "arguments": {"number": int(PR)}}))
        diff = _text(call("tools/call", {"name": "get_pr_diff", "arguments": {"number": int(PR)}}))
    except Exception as exc:  # advisory: never fail the review
        print(f"konflate evidence provider: {exc}", file=sys.stderr)
        _emit([])

    findings = []
    src = f"https://konflate.oxygn.dev/#/pr/{PR}"

    # konflate returns a plain sentinel when there's no usable diff yet —
    # PR not tracked ("No pull request #N is tracked.") or render still pending
    # ("has no rendered diff yet", "Still rendering"). Emit nothing in those
    # cases rather than presenting a placeholder as evidence.
    _SKIP = ("no pull request", "is tracked", "no rendered diff",
             "still rendering", "has no rendered")

    def _no_evidence(t):
        low = (t or "").lower()
        return (not t) or any(s in low for s in _SKIP)

    if _no_evidence(diff):
        _emit([])
    findings.append({
        "severity": "info",
        "message": "konflate rendered Flux diff (post-kustomize/Helm Kubernetes YAML — "
                   "the resources Flux will actually apply, not the raw template diff):\n\n"
                   f"{diff}",
        "source": src,
    })
    if summary and not _no_evidence(summary):
        findings.append({"severity": "info", "message": summary, "source": src})
    _emit(findings)

if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Créer `.github/scripts/upgrade_impact_evidence.py`**

Copie verbatim de jory (aucune adaptation — pas d'URL locale, `GITHUB_REPOSITORY` et `gh` fournis par le runner) :

```python
#!/usr/bin/env python3
"""Evidence provider: upstream upgrade impact for version-bump PRs.

Emits the action's evidence-provider JSON contract on stdout:
  {"severity": "info", "findings": [{"severity","message","source"}]}

Detects chart bumps (ocirepository.yaml tag changes) and container image bumps
(helmrelease.yaml image tag changes) in the PR diff, injects the deployment's
HelmRelease values, and fetches upstream GitHub release notes for the bumped
version range via authenticated `gh api`. Complements konflate: konflate shows
what changes in rendered manifests; this shows what changed upstream so the
model can cross-reference release notes against the values this repo sets.

Reads PR_NUMBER (and optionally GITHUB_REPOSITORY) from the environment, set
by the action. Read-only, advisory, never a gate: on any failure or a
non-bump PR it emits an empty findings list and exits 0.
"""
import json
import os
import re
import subprocess
import sys

PR = os.environ.get("PR_NUMBER", "").strip()
REPO = os.environ.get("GITHUB_REPOSITORY", "").strip()

MAX_RELEASES = 4
MAX_NOTES_BYTES = 3500
MAX_VALUES_BYTES = 4000
MAX_TOTAL_BYTES = 19000

_FILE_RE = re.compile(r"^\+\+\+ b/(.+)$")
_TAG_RE = re.compile(r"^([-+ ])\s*tag: (\S+)")
_URL_RE = re.compile(r"^[-+ ]\s*url: oci://(\S+)")
_REPOSITORY_RE = re.compile(r"^[-+ ]\s*repository: (\S+)")


def _emit(findings, severity="info"):
    print(json.dumps({"severity": severity, "findings": findings}))
    sys.exit(0)


def _clean_tag(tag):
    return tag.split("@", 1)[0].strip().strip('"')


def parse_bumps(diff_text):
    """Extract version bumps from a unified PR diff.

    Returns [{"path","kind","artifact","old","new"}] where kind is "chart"
    (ocirepository.yaml) or "image" (helmrelease.yaml). artifact may be None
    when the identifying url/repository line is outside the hunk; main()
    falls back to reading the file from the checkout.
    """
    bumps = []
    path = None
    image_repo = None
    old_tag = None
    for line in diff_text.splitlines():
        m = _FILE_RE.match(line)
        if m:
            path = m.group(1)
            image_repo = old_tag = None
            continue
        if path is None or not path.startswith("kubernetes/"):
            continue
        is_oci = path.endswith("ocirepository.yaml")
        is_hr = path.endswith("helmrelease.yaml")
        if not (is_oci or is_hr):
            continue
        m = _URL_RE.match(line)
        if m:
            # In OCIRepository manifests url: follows ref.tag, so the tag
            # pair is usually recorded before the url line is seen.
            for b in bumps:
                if b["path"] == path and b["kind"] == "chart" and b["artifact"] is None:
                    b["artifact"] = m.group(1)
            continue
        m = _REPOSITORY_RE.match(line)
        if m:
            image_repo = m.group(1).strip('"')
            continue
        m = _TAG_RE.match(line)
        if not m:
            continue
        sign, tag = m.group(1), _clean_tag(m.group(2))
        if sign == "-":
            old_tag = tag
        elif sign == "+" and old_tag is not None:
            if tag != old_tag:
                bumps.append({
                    "path": path,
                    "kind": "chart" if is_oci else "image",
                    "artifact": None if is_oci else image_repo,
                    "old": old_tag,
                    "new": tag,
                })
            old_tag = None
    return bumps


def parse_version(text):
    m = re.search(r"\d+(?:\.\d+)+", text or "")
    if not m:
        return None
    return tuple(int(p) for p in m.group(0).split("."))


def select_releases(releases, old, new):
    """Releases with version in (old, new], newest first, capped.

    Returns (selected, omitted_count). Unparseable `old` widens the lower
    bound; unparseable `new` selects nothing (can't bound the range).
    """
    lo, hi = parse_version(old), parse_version(new)
    if hi is None:
        return [], 0
    picked = []
    for r in releases:
        if r.get("draft") or r.get("prerelease"):
            continue
        v = parse_version(r.get("tag_name", ""))
        if v is None or v > hi:
            continue
        if lo is not None and v <= lo:
            continue
        picked.append((v, r))
    picked.sort(key=lambda t: t[0], reverse=True)
    return [r for _, r in picked[:MAX_RELEASES]], max(0, len(picked) - MAX_RELEASES)


_SOURCE_RE = re.compile(r"\[source\]\(https://github\.com/([^/)]+/[^/)#?]+)")


def resolve_repo_candidates(artifact, pr_body=""):
    cands = []
    parts = (artifact or "").split("/")
    if len(parts) >= 3 and "." in parts[0]:
        cands.append(f"{parts[1]}/{parts[2]}")
        if len(parts) > 3 and f"{parts[1]}/{parts[-1]}" not in cands:
            cands.append(f"{parts[1]}/{parts[-1]}")
    for m in _SOURCE_RE.finditer(pr_body or ""):
        slug = m.group(1).removesuffix(".git")
        if slug not in cands:
            cands.append(slug)
    return cands


def flatten_values(tree, prefix=""):
    """Flatten a nested values dict to dotted leaf paths; lists are leaves."""
    if not isinstance(tree, dict):
        return {}
    flat = {}
    for key, val in tree.items():
        path = f"{prefix}.{key}" if prefix else str(key)
        if isinstance(val, dict) and val:
            flat.update(flatten_values(val, path))
        else:
            flat[path] = val
    return flat


def values_drift(old_defaults, new_defaults, our_values):
    """Diff chart default values old→new and intersect with keys we set.

    A key we set that disappeared from the defaults is the headline signal:
    it may have been renamed upstream, silently turning our override into a
    no-op that renders identically.
    """
    old = flatten_values(old_defaults)
    new = flatten_values(new_defaults)
    ours = flatten_values(our_values)
    removed = [k for k in old if k not in new]
    added = [k for k in new if k not in old]
    changed = [k for k in old if k in new and old[k] != new[k]]
    return {
        "added": len(added),
        "removed": len(removed),
        "changed": len(changed),
        "removed_set_keys": sorted(k for k in removed if k in ours),
        "changed_set_keys": sorted((k, old[k], new[k]) for k in changed if k in ours),
    }


def _truncate(text, limit_bytes, marker=""):
    if len(text.encode()) <= limit_bytes:
        return text
    out = text.encode()[:limit_bytes].decode("utf-8", "replace").rstrip("\ufffd")
    return out + ("\n" + marker if marker else "")


def build_findings(ctxs):
    findings = []
    for ctx in ctxs:
        b = ctx["bump"]
        head = f"{b['artifact'] or b['path']} {b['old']} \u2192 {b['new']} ({b['kind']} bump)"
        if ctx.get("hr_text"):
            findings.append({
                "severity": "info",
                "message": (
                    f"Deployment configuration for {head}. These are the HelmRelease "
                    "values this repo sets — cross-reference upstream changes against "
                    "them and flag anything that affects configured behavior:\n\n"
                    f"```yaml\n{_truncate(ctx['hr_text'], MAX_VALUES_BYTES, '# [truncated]')}\n```"
                ),
                "source": ctx["hr_path"],
            })
        rels = ctx.get("releases") or []
        if rels:
            parts = []
            for r in rels:
                notes = _truncate((r.get("body") or "").strip(), MAX_NOTES_BYTES,
                                  f"[truncated — see {r.get('html_url', '')}]")
                parts.append(f"### {r.get('tag_name')} — {r.get('name') or ''}\n{notes}")
            skipped = ctx.get("skipped", 0)
            more = (f"\n\n({skipped} more releases in range omitted for size — see the "
                    "releases page.)") if skipped else ""
            findings.append({
                "severity": "info",
                "message": (
                    f"Upstream release notes for {head} — check them against the "
                    "HelmRelease values above:\n\n" + "\n\n".join(parts) + more
                ),
                "source": f"https://github.com/{ctx['repo_slug']}/releases",
            })
        drift = ctx.get("drift")
        if drift:
            totals = (f"{drift['added']} added / {drift['changed']} changed / "
                      f"{drift['removed']} removed")
            lines = []
            for k in drift["removed_set_keys"]:
                lines.append(f"- `{k}` — set in the HelmRelease but no longer in the "
                             "chart defaults; likely renamed or removed upstream, so "
                             "the override may now be a silent no-op. Verify against "
                             "the new chart.")
            for k, old_v, new_v in drift["changed_set_keys"]:
                lines.append(f"- `{k}` — upstream default changed {old_v!r} \u2192 {new_v!r} "
                             "(this repo overrides it, so behavior is unchanged, but "
                             "the upstream intent shifted).")
            if lines:
                body = "\n".join(lines)
            else:
                body = ("none intersect the values this repo sets — no configured "
                        "value was renamed, removed, or re-defaulted.")
            findings.append({
                "severity": "info",
                "message": (
                    f"Chart default values drift for {head} ({totals}): {body}"
                ),
                "source": b["path"],
            })
        if not rels and ctx.get("repo_slug") is None:
            findings.append({
                "severity": "info",
                "message": (
                    f"No upstream release notes retrievable for {head} — upstream "
                    "impact is unverified; treat this as a known blind spot and "
                    "do not guess changelog contents."
                ),
                "source": b["path"],
            })
    return findings


def fit_budget(findings):
    while findings and len(json.dumps(
            {"severity": "info", "findings": findings}).encode()) > MAX_TOTAL_BYTES:
        longest = max(findings, key=lambda f: len(f["message"].encode()))
        size = len(longest["message"].encode())
        if size <= 1000:
            findings.remove(longest)
            continue
        longest["message"] = _truncate(longest["message"], size // 2,
                                       "[truncated for size]")
    return findings


def _run(cmd, timeout=25):
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])} failed: {r.stderr.strip()[:200]}")
    return r.stdout


def _repo_args():
    return ["--repo", REPO] if REPO else []


def fetch_releases(slug):
    data = json.loads(_run(["gh", "api", f"repos/{slug}/releases?per_page=50"]))
    return data if isinstance(data, list) else []


def parse_helm_show_values(output):
    """Parse `helm show values` stdout; helm v4 prefixes Pulled:/Digest: lines
    before a `---` document separator."""
    import yaml
    lines = output.splitlines()
    for i, line in enumerate(lines):
        if line.startswith("---"):
            output = "\n".join(lines[i:])
            break
    data = yaml.safe_load(output)
    return data if isinstance(data, dict) else {}


def compute_chart_drift(bump, hr_text):
    """Default-values drift for a chart bump; None if unavailable.

    Requires helm and PyYAML; both may be missing on ARC runners (the workflow
    installs them). Any failure (missing tools, unpullable chart, unparseable
    YAML) skips the signal rather than failing the provider.
    """
    try:
        import yaml
        defaults = {}
        for ver in (bump["old"], bump["new"]):
            defaults[ver] = parse_helm_show_values(_run(
                ["helm", "show", "values", f"oci://{bump['artifact']}",
                 "--version", ver], timeout=60))
        ours = (yaml.safe_load(hr_text) or {}).get("spec", {}).get("values", {})
        return values_drift(defaults[bump["old"]], defaults[bump["new"]], ours)
    except Exception as exc:
        print(f"upgrade-impact: drift skipped for {bump['artifact']}: {exc}",
              file=sys.stderr)
        return None


def main():
    if not PR.isdigit():
        _emit([])
    try:
        bumps = parse_bumps(_run(["gh", "pr", "diff", PR, *_repo_args()], timeout=30))
        if not bumps:
            _emit([])
        try:
            pr_body = json.loads(_run(
                ["gh", "pr", "view", PR, *_repo_args(), "--json", "body"]))["body"] or ""
        except Exception:
            pr_body = ""
        ctxs = []
        for b in bumps:
            if b["artifact"] is None and b["kind"] == "chart":
                try:
                    with open(b["path"], encoding="utf-8") as f:
                        m = re.search(r"url: oci://(\S+)", f.read())
                    if m:
                        b["artifact"] = m.group(1)
                except OSError:
                    pass
            ctx = {"bump": b, "repo_slug": None}
            hr_path = os.path.join(os.path.dirname(b["path"]), "helmrelease.yaml")
            try:
                with open(hr_path, encoding="utf-8") as f:
                    ctx["hr_text"] = f.read()
                ctx["hr_path"] = hr_path
            except OSError:
                pass
            for slug in resolve_repo_candidates(b["artifact"], pr_body):
                try:
                    selected, skipped = select_releases(
                        fetch_releases(slug), b["old"], b["new"])
                except Exception:
                    continue
                if selected:
                    ctx.update(repo_slug=slug, releases=selected, skipped=skipped)
                    break
            if b["kind"] == "chart" and b["artifact"] and ctx.get("hr_text"):
                drift = compute_chart_drift(b, ctx["hr_text"])
                if drift is not None:
                    ctx["drift"] = drift
            ctxs.append(ctx)
        _emit(fit_budget(build_findings(ctxs)))
    except Exception as exc:  # advisory: never fail the review
        print(f"upgrade-impact evidence provider: {exc}", file=sys.stderr)
        _emit([])


if __name__ == "__main__":
    main()
```

Note : remplacer les `\u2192` par le caractère `→` si le fichier est écrit en UTF-8 direct (équivalent strict ; le JSON de sortie est identique).

- [ ] **Step 3: Créer `.github/konflate-evidence-providers.json`**

```json
[
  {
    "id": "konflate-rendered-diff",
    "command": ["python3", ".github/scripts/konflate_evidence.py"],
    "timeout_sec": 45
  },
  {
    "id": "upgrade-impact",
    "command": ["python3", ".github/scripts/upgrade_impact_evidence.py"],
    "timeout_sec": 90
  }
]
```

- [ ] **Step 4: Vérifier — compile + smoke tests**

Run:
```bash
python3 -m py_compile .github/scripts/konflate_evidence.py .github/scripts/upgrade_impact_evidence.py && echo COMPILE_OK
env -u PR_NUMBER python3 .github/scripts/konflate_evidence.py; echo "exit=$?"
env -u PR_NUMBER python3 .github/scripts/upgrade_impact_evidence.py; echo "exit=$?"
python3 -c "import json; json.load(open('.github/konflate-evidence-providers.json')); print('JSON_OK')"
```
Expected: `COMPILE_OK` ; les deux scripts affichent `{"severity": "info", "findings": []}` avec `exit=0` ; `JSON_OK`.

- [ ] **Step 5: Test unitaire de `parse_bumps` (fonction pure, sans réseau)**

Run:
```bash
python3 - <<'EOF'
import importlib.util
spec = importlib.util.spec_from_file_location("uie", ".github/scripts/upgrade_impact_evidence.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
diff = """diff --git a/kubernetes/apps/network/cloudflared/app/ocirepository.yaml b/kubernetes/apps/network/cloudflared/app/ocirepository.yaml
--- a/kubernetes/apps/network/cloudflared/app/ocirepository.yaml
+++ b/kubernetes/apps/network/cloudflared/app/ocirepository.yaml
@@ -1,5 +1,5 @@
 spec:
   ref:
-    tag: 2025.1.0
+    tag: 2025.2.0
   url: oci://ghcr.io/home-operations/cloudflared
"""
bumps = m.parse_bumps(diff)
assert bumps == [{"path": "kubernetes/apps/network/cloudflared/app/ocirepository.yaml",
                   "kind": "chart", "artifact": "ghcr.io/home-operations/cloudflared",
                   "old": "2025.1.0", "new": "2025.2.0"}], bumps
assert m.parse_bumps("") == []
print("PARSE_BUMPS_OK")
EOF
```
Expected: `PARSE_BUMPS_OK`

- [ ] **Step 6: Commit**

```bash
git add .github/scripts/ .github/konflate-evidence-providers.json
git commit -m "feat(ci): add ai-pr-review evidence providers"
```

---

### Task 2: System prompt instructions

**Files:**
- Create: `.agents/instructions/pr-review.instructions.md`

**Interfaces:**
- Consumes (Task 3): le workflow passe `system_prompt_file: .agents/instructions/pr-review.instructions.md` + `system_prompt_mode: append`. Le fichier doit exister à la racine du repo au path exact.

- [ ] **Step 1: Créer `.agents/instructions/pr-review.instructions.md`**

Adapté de jory, aligné sur notre AGENTS.md (mêmes conventions + nôtre contexte) :

```markdown
# Home-ops PR review conventions

This file is the `system_prompt_file` for the AI PR Review workflow
(`.github/workflows/ai-pr-review.yaml`), used with `system_prompt_mode: append`:
the action keeps its (conditionally-assembled) bundled default system prompt and
appends this file as a repo-specific addendum. Only home-ops conventions live
here — the base review instructions, output schema, and host-platform / digest
guidance come from the action and no longer need to be copied or kept in sync.

## Home-ops conventions

The conventions in the repository's `AGENTS.md` are authoritative for this project. Repository-specific conventions documented there override generic Kubernetes, Helm, Flux, or GitOps linting heuristics.

If a pattern is explicitly documented as intentional in `AGENTS.md` (or in the conventions listed below), do not surface it as a concern, warning, or "for awareness" note in the review.

### Documented conventions to honour without flagging

- **`metadata.namespace` is intentionally absent on `HelmRelease` and `Kustomization` resources.** The namespace is injected at build time by kustomize's `namespace:` directive in the per-app `kustomization.yaml` (e.g. `namespace: ai`). For Flux `Kustomization` resources, `spec.targetNamespace` is propagated automatically via the replacement component at `kubernetes/components/replacements/ks.yaml`. Do not flag the absence of `metadata.namespace` on these resources as an issue.

- **OCI artifacts are pinned by tag/version, not by SHA digest.** The "Prefer `@sha256:` digests" policy in `AGENTS.md` applies to container images only. OCI artifacts pulled via `OCIRepository` (Helm charts in OCI registries) are pinned by tag or version, since OCI artifacts do not support SHA-tag references the same way container images do. Do not flag the absence of `@sha256:` on OCI artifact references.

- **The GPU worker node `k8s-3` is tainted `workload=ai:NoSchedule`.** Workloads targeting it intentionally carry a matching toleration and usually a `nodeSelector` on `kubernetes.io/hostname: k8s-3` — this is the established pattern (`nvidia-device-plugin`, `toolhive` `EmbeddingServer`), not a scheduling mistake.

- **`ClientTrafficPolicy` and `EnvoyPatchPolicy` targeting a `Gateway` live in the Gateway's namespace.** For `envoy-internal` this means the `network` namespace by design — not a misplaced resource.

### Compact Renovate digest-only reviews

For Renovate digest-only container image updates where the repository and tag are unchanged and the diff only changes `@sha256:` values, keep `review_markdown` compact.

Prefer:

- short recommendation
- changed files summary
- non-blocking caveats, if any

Do not include separate Standards Compliance, Linked Issue Fit, Evidence Provider Findings, Tool Harness Findings, or Unknowns sections unless they contain an actual warning or blocker.

Do not include internal planner/tool-harness diagnostics such as missing `requests[]` unless they affect the recommendation.

Missing OCI revision/source labels are a non-blocking caveat for same-tag digest refreshes when repository, tag, and created timestamp evidence are consistent.

### Konflate rendered-diff tools

A Konflate MCP server is configured. Konflate renders Helm charts and Kustomizations into their final Kubernetes manifests, so its rendered diff shows the actual cluster impact of a PR — not just the raw git changes. A rendered-diff summary is usually already injected into the corpus by the konflate evidence provider; use the MCP tools when you need more than the summary provides.

- `mcp__konflate__get_pr_summary` — pass the current PR `number`. Blast radius (added/changed/removed resources), caution lint (data-loss, immutable-field, RBAC, suspend/prune), image changes, render failures. Cheap and high-value; call this first if the evidence section is missing or stale.
- `mcp__konflate__get_pr_diff` — pass the current PR `number`. The full rendered manifest diff (Kubernetes YAML at PR head vs merge-base). Use it when the raw git diff hides the real change — e.g. a HelmRelease version bump or a one-line `values` change that fans out across many resources.

Konflate signals in the review: surface cautions as caveats or blockers by severity; treat render failures as blockers (the manifests may not apply cleanly). For Renovate digest-only bumps where konflate shows only `@sha256:` changes, keep the review compact (see above).

### Upstream verification is mandatory for upgrades

Check upstream for breaking changes before recommending approval of any version bump — that is part of your job. Cross-reference the injected upstream release notes (upgrade-impact evidence) against the HelmRelease values this repo sets, and use `gh_api` / `web_search` when the injected evidence is missing or truncated. If upstream impact cannot be verified, say so explicitly as a blind spot instead of guessing changelog contents.
```

- [ ] **Step 2: Vérifier le fichier**

Run:
```bash
test -f .agents/instructions/pr-review.instructions.md && grep -c "system_prompt_mode: append" .agents/instructions/pr-review.instructions.md
```
Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add .agents/instructions/pr-review.instructions.md
git commit -m "feat(ci): add ai pr-review system prompt instructions"
```

---

### Task 3: Workflow + label

**Files:**
- Modify: `.github/labels.yaml` (section "Uncategorized", après `hold`)
- Create: `.github/workflows/ai-pr-review.yaml`

**Interfaces:**
- Consumes: Task 1 (`.github/konflate-evidence-providers.json`), Task 2 (`.agents/instructions/pr-review.instructions.md`), secrets/vars GitHub (Task 4 — le workflow peut être mergé avant, il échouera proprement tant que les secrets manquent : `create-github-app-token` échoue → job rouge, pas de review. Acceptable uniquement si Task 4 suit immédiatement).
- Produces: workflow `AI PR Review` déclenché sur PRs non-draft vers main + `workflow_dispatch`, label `ai-review` géré par l'action (`rereview_label` par défaut).

- [ ] **Step 1: Ajouter le label `ai-review` dans `.github/labels.yaml`**

Dans la section `# Uncategorized`, après le label `hold` :

```yaml
# Uncategorized
- name: hold
  color: "ee0701"
- name: ai-review
  color: "5319e7"
```

- [ ] **Step 2: Créer `.github/workflows/ai-pr-review.yaml`**

Adaptations vs jory : `runs-on: home-ops-runner`, step setup helm/PyYAML (runners ARC ≠ ubuntu-latest), URLs oxygn.dev, secrets `APP_CLIENT_ID`/`APP_PRIVATE_KEY`/`LITELLM_API_KEY`, vars `LITELLM_URL`/`PRIMARY_MODEL`/`SMART_MODEL`/`FALLBACK_MODEL`, formats hardcoded `openai`, `allowed_source_hosts` sans les hosts minecraft.

```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/github-workflow.json
name: AI PR Review

on:
  pull_request:
    branches: ["main"]
    # `labeled` enables the one-click re-review: add the `ai-review` label to
    # force a fresh review (only write/triage can label — self-authorizing).
    types: [opened, reopened, synchronize, ready_for_review, labeled]
  workflow_dispatch:
    inputs:
      pr_number:
        description: PR number to (re-)review
        required: true

concurrency:
  # `labeled` events each get their own group: net-new PRs are auto-labeled
  # (Renovate adds several at creation), and with a shared group +
  # cancel-in-progress those label runs would cancel the real opened review.
  group: ${{ github.workflow }}-${{ github.event.pull_request.number || inputs.pr_number || github.ref }}${{ github.event.action == 'labeled' && format('-label-{0}', github.run_id) || '' }}
  cancel-in-progress: true

permissions:
  contents: read
  pull-requests: write

jobs:
  review-pr:
    name: AI PR Review
    # pull_request is the normal path; adding the `ai-review` label is the
    # normal re-review trigger (handled natively by the action). workflow_dispatch
    # remains as a manual force-review path.
    if: ${{ (github.event_name == 'pull_request' && !github.event.pull_request.draft) || github.event_name == 'workflow_dispatch' }}
    runs-on: home-ops-runner
    timeout-minutes: 35

    steps:
      - name: Resolve PR head for re-review
        id: prctx
        if: github.event_name == 'workflow_dispatch'
        env:
          GH_TOKEN: ${{ github.token }}
          PR_NUMBER: ${{ inputs.pr_number }}
        run: |
          sha="$(gh api "repos/${GITHUB_REPOSITORY}/pulls/${PR_NUMBER}" --jq '.head.sha')"
          echo "head_sha=$sha" >> "$GITHUB_OUTPUT"

      - name: Checkout
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          fetch-depth: 0
          ref: ${{ github.event.pull_request.head.sha || steps.prctx.outputs.head_sha }}

      - name: Setup review tooling
        # ARC runners lack helm/PyYAML (preinstalled on ubuntu-latest); the
        # upgrade-impact evidence provider needs them for chart-values drift.
        run: |
          command -v helm >/dev/null 2>&1 || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
          python3 -c 'import yaml' 2>/dev/null || python3 -m pip install --user --break-system-packages pyyaml 2>/dev/null || python3 -m pip install --user pyyaml

      - name: Generate bot token
        id: app-token
        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0
        with:
          client-id: ${{ secrets.APP_CLIENT_ID }}
          private-key: ${{ secrets.APP_PRIVATE_KEY }}

      - name: Analyze PR with reusable AI reviewer
        id: analyze
        uses: misospace/pr-reviewer-action@54dfb1aac20e1e410ad8f71dc3681b888500a1ec # v2.2.1
        env:
          # konflate's read-only MCP endpoint — the konflate evidence provider
          # fetches the rendered (post-kustomize/Helm) Flux diff for this PR.
          KONFLATE_MCP_URL: https://konflate.oxygn.dev/mcp
        with:
          github_token: ${{ steps.app-token.outputs.token }}
          pr_number: ${{ github.event.pull_request.number || inputs.pr_number }}
          force_review: ${{ github.event_name == 'workflow_dispatch' && 'true' || 'false' }}
          ai_primary_retries: "3"
          ai_primary_retry_delay_sec: "15"
          ai_base_url: ${{ vars.LITELLM_URL }}
          ai_api_format: openai
          ai_model: ${{ vars.PRIMARY_MODEL }}
          ai_api_key: ${{ secrets.LITELLM_API_KEY }}
          ai_response_format: json_object
          ai_max_tokens: "16000"
          ai_fallback_base_url: ${{ vars.LITELLM_URL }}
          ai_fallback_api_format: openai
          ai_fallback_model: ${{ vars.FALLBACK_MODEL }}
          ai_fallback_api_key: ${{ secrets.LITELLM_API_KEY }}
          review_routing_mode: auto
          ai_smart_base_url: ${{ vars.LITELLM_URL }}
          ai_smart_api_format: openai
          ai_smart_model: ${{ vars.SMART_MODEL }}
          ai_smart_api_key: ${{ secrets.LITELLM_API_KEY }}
          allowed_source_hosts: "github.com,api.github.com,gitlab.com,registry.terraform.io,artifacthub.io,talos.dev,www.talos.dev,docs.siderolabs.com"
          context_limit_mode: normal
          ci_status_check: "true"
          ci_timeout_sec: "600"
          search_url: "https://search.oxygn.dev/search"
          tool_mode: native_loop
          tool_max_rounds: "2"
          tool_max_requests: "4"
          tool_loop_wall_clock_sec: "600"
          tool_planning_timeout_sec: "300"
          tool_planning_max_context_bytes: "15000"
          tool_planning_max_tokens: "16000"
          tool_max_response_bytes: "12000"
          tool_allowed_gh_api_repos: "*"
          tool_request_timeout_sec: "15"
          tool_enable_for_forks: "false"
          # Read-only konflate MCP tools for the native loop (advertised as
          # mcp__konflate__get_pr_summary / get_pr_diff / list_pull_requests).
          # Complements the evidence provider below: the provider injects the
          # rendered-diff summary deterministically; MCP lets the model do
          # follow-up digging (e.g. pull the full rendered diff on demand).
          tool_mcp_servers: "konflate=https://konflate.oxygn.dev/mcp"
          system_prompt_file: .agents/instructions/pr-review.instructions.md
          system_prompt_mode: append
          standards_file_candidates: "AGENTS.md"
          # Read-only konflate MCP: injects the rendered Flux YAML diff (the
          # resources Flux will actually apply) as advisory evidence. Never
          # gates — the provider exits clean with no findings on any failure
          # or for PRs konflate isn't tracking.
          evidence_providers_file: .github/konflate-evidence-providers.json
          on_model_failure: notice
          inline_findings: "true"
          publish_mode: review_comment
```

- [ ] **Step 3: Vérifier — parse YAML + structure**

Run:
```bash
python3 - <<'EOF'
import yaml
wf = yaml.safe_load(open('.github/workflows/ai-pr-review.yaml'))
job = wf['jobs']['review-pr']
steps = {s.get('name'): s for s in job['steps']}
assert job['runs-on'] == 'home-ops-runner'
assert steps['Analyze PR with reusable AI reviewer']['with']['publish_mode'] == 'review_comment'
assert steps['Analyze PR with reusable AI reviewer']['env']['KONFLATE_MCP_URL'] == 'https://konflate.oxygn.dev/mcp'
assert steps['Generate bot token']['with']['client-id'] == '${{ secrets.APP_CLIENT_ID }}'
labels = yaml.safe_load(open('.github/labels.yaml'))
assert any(l['name'] == 'ai-review' for l in labels)
print('WORKFLOW_OK')
EOF
```
Expected: `WORKFLOW_OK`

- [ ] **Step 4: Vérifier les SHAs pinés (Renovate les gérera ensuite)**

Run:
```bash
grep -o "actions/checkout@[a-f0-9]\{40\}\|create-github-app-token@[a-f0-9]\{40\}\|pr-reviewer-action@[a-f0-9]\{40\}" .github/workflows/ai-pr-review.yaml
```
Expected: 3 lignes — checkout@3d3c42e…, create-github-app-token@bcd2ba4…, pr-reviewer-action@54dfb1a…

- [ ] **Step 5: Commit**

```bash
git add .github/labels.yaml .github/workflows/ai-pr-review.yaml
git commit -m "feat(ci): add ai-pr-review workflow and label"
```

---

### Task 4: Config GitHub, PR et vérification end-to-end

**Files:**
- Aucun fichier repo. Modifie la config du repo GitHub (secrets, vars) et ouvre la PR.

**Interfaces:**
- Consumes: Tasks 1–3 commités sur `add-ai-pr-review`.
- Produces: secrets `APP_CLIENT_ID`/`APP_PRIVATE_KEY`/`LITELLM_API_KEY`, vars `LITELLM_URL`/`PRIMARY_MODEL`/`SMART_MODEL`/`FALLBACK_MODEL`, PR ouverte → le workflow tourne sur cette PR (dogfooding).

- [ ] **Step 1: Vérifier l'accès gh + kubectl**

Run:
```bash
gh auth status && kubectl get secret konflate -n flux-system >/dev/null && kubectl get secret litellm-secret -n ai >/dev/null && echo ACCESS_OK
```
Expected: authentifié sur OxygnCorp/home-ops, secrets lisibles, `ACCESS_OK`.
Si kubectl n'est pas configuré : demander à l'utilisateur les valeurs depuis 1Password (item `github` → `GITHUB_APP_PRIVATE_KEY`, item `litellm` → `LITELLM_MASTER_KEY`) et passer directement les valeurs aux commandes du Step 2.

- [ ] **Step 2: Créer secrets et vars**

```bash
gh secret set APP_CLIENT_ID --body "Iv23lizpdaSYJBX0uzo8"
kubectl get secret konflate -n flux-system -o jsonpath='{.data.KONFLATE_APP_PRIVATE_KEY}' | base64 -d | gh secret set APP_PRIVATE_KEY
kubectl get secret litellm-secret -n ai -o jsonpath='{.data.LITELLM_MASTER_KEY}' | base64 -d | gh secret set LITELLM_API_KEY
gh variable set LITELLM_URL --body "https://litellm.oxygn.dev/v1"
gh variable set PRIMARY_MODEL --body "dsv4f"
gh variable set SMART_MODEL --body "zai-glm-5.2"
gh variable set FALLBACK_MODEL --body "MiniMax-M3"
```
Expected: chaque commande confirme la création (`✓ Set secret…` / `✓ Set variable…`).

- [ ] **Step 3: Pousser et ouvrir la PR**

```bash
git push -u origin add-ai-pr-review
gh pr create --title "feat(ci): add AI PR Review workflow" --body "$(cat <<'EOF'
## Summary

Porte le workflow AI PR Review de [joryirving/home-ops](https://github.com/joryirving/home-ops/blob/3d30152f24455de010aedf6d0653da0339a287a4/.github/workflows/ai-pr-review.yaml), adapté à notre infra :

- Reviewer AI via `misospace/pr-reviewer-action@v2.2.1` sur le runner `home-ops-runner`
- Routage LiteLLM : primary `dsv4f` / smart `zai-glm-5.2` / fallback `MiniMax-M3`
- Evidence providers : diff Flux rendu konflate (`konflate.oxygn.dev/mcp`) + release notes amont & drift des values Helm
- Identité : app GitHub konflate partagée (reviews advisory, `review_comment`)
- Re-review one-click via le label `ai-review`

Spec : `docs/superpowers/specs/2026-08-30-ai-pr-review-design.md`

**Ne pas merger** tant que la review AI de cette PR n'est pas passée (dogfooding) et que la section konflate rendered diff n'est pas visible.
EOF
)"
```
Expected: URL de la PR affichée.

- [ ] **Step 4: Vérifier le run end-to-end**

```bash
sleep 30 && gh run list --workflow=ai-pr-review.yaml --limit 1
```
Expected: un run `AI PR Review` sur la PR, runner `home-ops-runner`.

```bash
gh run watch $(gh run list --workflow=ai-pr-review.yaml --limit 1 --json databaseId --jq '.[0].databaseId')
```
Expected: conclusion `success`.

Puis vérifier sur la PR (`gh pr view <num> --comments` + onglet Conversation) :
1. Une review native du bot konflate (non app userIdentity) avec `publish_mode: review_comment` — **non bloquante**
2. Les findings inline sont ancrés aux lignes du diff
3. La review mentionne le diff rendu konflate (evidence) — le repo étant tracké par konflate (`github://OxygnCorp/home-ops`), la section doit apparaître
4. La review respecte les conventions (ne flagge pas l'absence de `metadata.namespace`)

- [ ] **Step 5: Tester la re-review par label**

```bash
gh pr edit <num> --add-label ai-review || gh issue edit <num> --add-label ai-review
sleep 60 && gh run list --workflow=ai-pr-review.yaml --limit 2
```
Expected: un nouveau run déclenché par l'événement `labeled` ; après complétion, le label `ai-review` a été retiré automatiquement par l'action.

- [ ] **Step 6: Vérifier le label-sync**

Après merge, `label-sync.yaml` applique `labels.yaml` :
```bash
gh label list --json name --jq '.[].name' | grep -x ai-review
```
Expected: `ai-review` (déjà créé au Step 5 par l'action ou par label-sync).

---

## Self-Review (fait après écriture)

1. **Spec coverage** : workflow (T3), instructions (T2), 2 scripts + JSON (T1), label (T3), secrets/vars GitHub (T4), validation end-to-end incl. re-review label et konflate rendered diff (T4 Steps 4–5) ✔. Virtual key LiteLLM = évolution optionnelle notée en spec, volontairement hors plan ✔.
2. **Placeholders** : aucun TBD ; code complet dans chaque step (les deux scripts sont reproduits intégralement, le workflow est complet) ✔.
3. **Cohérence** : noms de secrets/vars identiques entre T3 (workflow) et T4 (commandes gh) — `APP_CLIENT_ID`, `APP_PRIVATE_KEY`, `LITELLM_API_KEY`, `LITELLM_URL`, `PRIMARY_MODEL`, `SMART_MODEL`, `FALLBACK_MODEL` ✔. Path `evidence_providers_file` = `.github/konflate-evidence-providers.json` (T1/T3) ✔. `system_prompt_file` = `.agents/instructions/pr-review.instructions.md` (T2/T3) ✔. Steps du Task 4 renumérotés 1–6.

NOTE d'exécution : le Task 4 Step 2 manipule des secrets — ne jamais afficher les valeurs en sortie (`gh secret set` ne les echo pas ; les commandes kubectl pipe directement).
