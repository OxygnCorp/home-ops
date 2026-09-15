#!/usr/bin/env python3
# Foreman label watcher: GitHub issues labeled `foreman/ready` become Foreman
# Workload CRs. Stateless on disk — the Workload CRs themselves are the state:
# a Workload only ever exists while the pipeline is running, or until its
# outcome has been reported back to the issue. Failed workloads are retried
# with an escalation coder once, then the label is dropped for a human to
# pick up. GitHub label cleanup is best-effort: a PAT without issues:write
# only degrades the reporting, the pipeline keeps working.
import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request

REPO = os.environ.get("REPO", "OxygnCorp/home-ops")
NS = os.environ.get("WORKLOAD_NS", "ai")
LABEL = os.environ.get("LABEL", "foreman/ready")
ORG = REPO.split("/")[0]
MAX_IN_PROGRESS = int(os.environ.get("MAX_IN_PROGRESS", "2"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "2"))
ATTEMPT_ANNOTATION = "oxygn.dev/foreman-attempt"
TERMINAL = ("Completed", "Failed")
GH = "https://api.github.com"
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
SSL_CTX = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")


def req(url, *, data=None, method=None, headers=None, ctx=None):
    req = urllib.request.Request(
        url, headers=headers or {},
        data=json.dumps(data).encode() if data is not None else None,
        method=method or ("POST" if data is not None else "GET"))
    with urllib.request.urlopen(req, timeout=30, context=ctx) as resp:
        try:
            return json.load(resp)
        except json.JSONDecodeError:
            return None


def gh(path, data=None, method=None):
    return req(f"{GH}{path}",
               data=data, method=method,
               headers={"Authorization": f"Bearer {os.environ['GITHUB_TOKEN']}",
                        "User-Agent": "foreman-watcher",
                        "Accept": "application/vnd.github+json"})


def k8s(path, data=None, method=None):
    token = open(f"{SA_DIR}/token").read().strip()
    return req(f"https://{os.environ['KUBERNETES_SERVICE_HOST']}:"
               f"{os.environ['KUBERNETES_SERVICE_PORT_HTTPS']}{path}",
               data=data, method=method,
               headers={"Authorization": f"Bearer {token}",
                        "Accept": "application/json",
                        "Content-Type": "application/json"},
               ctx=SSL_CTX)


def branch_of(issue):
    return f"foreman/wx-{issue}/issue-{issue}"


def clear_branch(issue):
    ref = urllib.parse.quote(branch_of(issue), safe="")
    try:
        gh(f"/repos/{REPO}/git/refs/heads/{ref}", method="DELETE")
        print(f"  cleared remote branch for issue {issue}", flush=True)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise


def report(issue, text):
    try:
        gh(f"/repos/{REPO}/issues/{issue}/comments", data={"body": text})
    except urllib.error.HTTPError as e:
        print(f"  comment failed on #{issue}: HTTP {e.code} (issues:write?)", flush=True)


def drop_label(issue):
    try:
        gh(f"/repos/{REPO}/issues/{issue}/labels/{LABEL}", method="DELETE")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print(f"  label drop failed on #{issue}: HTTP {e.code} (issues:write?)", flush=True)


def make_workload(issue, title, attempt):
    spec = {
        "apiVersion": "foreman.llmkube.dev/v1alpha1",
        "kind": "Workload",
        "metadata": {
            "name": f"wx-{issue}",
            "namespace": NS,
            "labels": {"app.kubernetes.io/managed-by": "foreman-watcher"},
            "annotations": {ATTEMPT_ANNOTATION: str(attempt)},
        },
        "spec": {
            "intent": title,
            "repo": REPO,
            "issues": [issue],
            "coderAgentRef": {"name": "coder"},
            "reviewerAgentRefs": [{"name": "reviewer"}],
        },
    }
    if attempt >= MAX_ATTEMPTS:
        spec["spec"]["escalationCoderAgentRef"] = {"name": "coder-escalation"}
    k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads", data=spec)
    print(f"  created Workload wx-{issue} (attempt {attempt}){' — escalated' if attempt >= MAX_ATTEMPTS else ''}", flush=True)


wl_list = k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads")["items"]
by_issue, active = {}, 0
for wl in wl_list:
    name = wl["metadata"].get("name", "")
    if not name.startswith("wx-"):
        continue
    issue = int(name[3:])
    by_issue[issue] = wl
    if (wl.get("status") or {}).get("phase") not in TERMINAL:
        active += 1

print(f"{active} active workloads, {len(by_issue)} tracked", flush=True)

ready = [i for i in gh(f"/repos/{REPO}/issues?labels={urllib.parse.quote(LABEL, safe='')}"
                       f"&state=open&per_page=50") if "pull_request" not in i]

for issue in ready:
    n = issue["number"]
    title = issue["title"]
    name = f"wx-{n}"
    wl = by_issue.get(name)
    phase = (wl.get("status") or {}).get("phase") if wl else None
    print(f"# {n} {title}", flush=True)

    if wl is None:
        if active >= MAX_IN_PROGRESS:
            print("  skipped — MAX_IN_PROGRESS reached", flush=True)
            continue
        make_workload(n, title, 1)
        active += 1
        continue

    if phase not in TERMINAL:
        print(f"  still in flight ({phase}) — counted toward MAX_IN_PROGRESS", flush=True)
        continue

    prs = gh(f"/repos/{REPO}/pulls?state=open&head={ORG}:{branch_of(n)}")
    attempts = int((wl["metadata"].get("annotations") or {}).get(ATTEMPT_ANNOTATION, "1"))

    if prs:
        report(n, f"🤖 foreman pipeline completed — PR #{prs[0]['number']}: {prs[0]['html_url']}")
        drop_label(n)
        k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads/{name}", method="DELETE")
    elif phase == "Failed" and attempts < MAX_ATTEMPTS:
        # The harness cannot force-push, and a survivor branch would reject
        # the retry's push — clear the remote branch before recreating.
        clear_branch(n)
        k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads/{name}", method="DELETE")
        make_workload(n, title, attempts + 1)
        active += 1
    elif phase == "Failed":
        report(n, f"🤖 foreman gave up after {attempts} attempts — human triage needed. "
                  f"Branch `{branch_of(n)}` may hold partial work.")
        drop_label(n)
        k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads/{name}", method="DELETE")
    else:  # Completed but no PR found
        report(n, "🤖 foreman pipeline completed (no open PR found — work may already "
                  "be merged or resolved).")
        drop_label(n)
        k8s(f"/apis/foreman.llmkube.dev/v1alpha1/namespaces/{NS}/workloads/{name}", method="DELETE")

print("done", flush=True)
