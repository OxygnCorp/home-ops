#!/usr/bin/env python3
"""phoenix-evals nightly LLM-as-judge over Phoenix traces.

1. Fetch the Phoenix project + the latest N spans.
2. Have each trace judged by litellm (LLM-as-judge).
3. Publish scores as Phoenix span annotations (REST v1, annotator_kind LLM).
4. Append failing traces to a Phoenix regression dataset
   (incrementally enriched, never recreated).

Stdlib only — no pip install.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

PHOENIX = os.environ["PHOENIX_BASE_URL"].rstrip("/")
PHX_API_KEY = os.environ["PHOENIX_SYSTEM_API_KEY"]
LITELLM_BASE = os.environ["LITELLM_BASE_URL"].rstrip("/")
LITELLM_KEY = os.environ["LITELLM_API_KEY"]
LITELLM_MODEL = os.environ.get("PHOENIX_EVALS_JUDGE_MODEL", "dsv41f")
PROJECT = os.environ.get("PHOENIX_EVALS_PROJECT", "default")
DATASET_NAME = os.environ.get("PHOENIX_EVALS_DATASET", "phoenix-evals-failures")
MAX_SPANS = int(os.environ.get("PHOENIX_EVALS_MAX_SPANS", "50"))
FAIL_THRESHOLD = float(os.environ.get("PHOENIX_EVALS_THRESHOLD", "0.5"))
IDENTIFIER = "phoenix-evals"


def req(method, url, token, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(url, data=data, method=method)
    r.add_header("Authorization", f"Bearer {token}")
    if body is not None:
        r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors="replace")[:500]
        print(f"{method} {url} -> {e.code}: {msg}", file=sys.stderr)
        raise


def extract_text(span, key):
    attrs = span.get("attributes") or {}
    val = attrs.get(f"{key}.value")
    if val is None:
        val = attrs.get(key)
    if isinstance(val, dict):
        val = val.get("value")
    if val is None:
        return ""
    return str(val)


def judge(span):
    """Return (score 0..1, reason) or (None, None) on parse failure."""
    input_text = extract_text(span, "input")
    output_text = extract_text(span, "output")
    prompt = (
        "You are grading a single LLM agent exchange.\n"
        f"User request: {input_text}\n"
        f"Assistant/tool response: {output_text}\n"
        'Score correctness & tool-use sanity on 0-1. Answer STRICT JSON '
        '{"score": <float>, "reason": "<one line>"}'
    )
    try:
        resp = req("POST", f"{LITELLM_BASE}/v1/chat/completions", LITELLM_KEY, {
            "model": LITELLM_MODEL,
            "messages": [
                {"role": "system", "content": "You are a terse LLM-as-judge; output strict JSON only."},
                {"role": "user", "content": prompt},
            ],
            "temperature": 0.0,
        })
    except Exception as e:
        print(f"judge request error ({e}); skipping span", file=sys.stderr)
        return None, None
    try:
        content = resp["choices"][0]["message"]["content"]
    except (KeyError, TypeError, IndexError) as e:
        print(f"judge response shape error ({e}); skipping span", file=sys.stderr)
        return None, None
    if not isinstance(content, str):
        print("judge returned non-string content; skipping span", file=sys.stderr)
        return None, None
    # Strip markdown fences if present.
    text = content.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        m = re.search(r"\{.*\}", text, re.DOTALL)
        if not m:
            print("judge parse error; skipping span", file=sys.stderr)
            return None, None
        try:
            payload = json.loads(m.group(0))
        except json.JSONDecodeError:
            print("judge parse error; skipping span", file=sys.stderr)
            return None, None
    try:
        score = float(payload["score"])
        reason = str(payload.get("reason", ""))
    except (KeyError, ValueError, TypeError) as e:
        print(f"judge parse error ({e}); skipping span", file=sys.stderr)
        return None, None
    return score, reason


def get_project_id():
    # Direct lookup by name first.
    try:
        resp = req("GET", f"{PHOENIX}/v1/projects/{urllib.parse.quote(PROJECT, safe='')}", PHX_API_KEY)
        data = resp.get("data") or {}
        if data.get("id"):
            return data["id"]
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    # Fallback: list + filter.
    resp = req("GET", f"{PHOENIX}/v1/projects", PHX_API_KEY)
    for p in (resp.get("data") or []):
        if p.get("name") == PROJECT:
            return p["id"]
    sys.exit(f"project {PROJECT!r} not found in Phoenix")


def list_spans(project_id):
    params = {
        "limit": str(min(MAX_SPANS, 1000)),
        "sort": "start_time",
        "order": "desc",
    }
    qs = urllib.parse.urlencode(params)
    url = f"{PHOENIX}/v1/projects/{urllib.parse.quote(project_id, safe='')}/spans?{qs}"
    resp = req("GET", url, PHX_API_KEY)
    return (resp.get("data") or [])[:MAX_SPANS]


def dataset_exists():
    qs = urllib.parse.urlencode({"name": DATASET_NAME})
    url = f"{PHOENIX}/v1/datasets?{qs}"
    resp = req("GET", url, PHX_API_KEY)
    rows = resp.get("data") or []
    for r in rows:
        if r.get("name") == DATASET_NAME:
            return True
    return False


def main():
    project_id = get_project_id()
    spans = list_spans(project_id)

    annotations = []
    failures = []
    span_ids_fail = []

    for span in spans:
        score, reason = judge(span)
        if score is None:
            continue
        span_id = (span.get("context") or {}).get("span_id")
        label = "good" if score >= FAIL_THRESHOLD else "bad"
        annotations.append({
            "span_id": span_id,
            "name": "quality",
            "annotator_kind": "LLM",
            "result": {
                "label": label,
                "score": score,
                "explanation": reason,
            },
            "identifier": IDENTIFIER,
        })
        if score < FAIL_THRESHOLD:
            input_text = extract_text(span, "input")
            output_text = extract_text(span, "output")
            failures.append({
                "input": {"value": input_text},
                "output": {"value": output_text},
            })
            span_ids_fail.append(span_id)

    if annotations:
        req("POST", f"{PHOENIX}/v1/span_annotations?sync=true", PHX_API_KEY,
            {"data": annotations})

    if failures:
        action = "append" if dataset_exists() else "create"
        inputs = [f["input"] for f in failures]
        outputs = [f["output"] for f in failures]
        metadata = [{"source": "phoenix-evals", "annotator": "LLM"} for _ in failures]
        body = {
            "action": action,
            "name": DATASET_NAME,
            "description": "Regression dataset, auto-fed by nightly failures",
            "inputs": inputs,
            "outputs": outputs,
            "metadata": metadata,
            "span_ids": [sid for sid in span_ids_fail if sid],
        }
        req("POST", f"{PHOENIX}/v1/datasets/upload?sync=true", PHX_API_KEY, body)

    print(f"phoenix-evals done: {len(annotations)} annotations, {len(failures)} dataset rows added.")


if __name__ == "__main__":
    main()
