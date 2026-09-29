"""Inject a stable OpenCode Go session header and route per session.

OpenCode Go (Console Go) requires a stable per-conversation `x-opencode-session`
for routing and prompt-cache affinity. Agents (openclaw, opencode) always send
one — forwarded as-is. Headless services (memini, lightrag, ...) have no
conversation identity: they get one shared, stable routing identity so their
calls and their litellm router fallbacks onto OpenCode Go succeed.

Sticky-per-session load-balancing
---------------------------------
Two OpenCode Go subscriptions are wired in parallel (`OPENCODE_MATT_API_KEY`,
`OPENCODE_AGNES_API_KEY`). To keep each openclaw session pinned to one
subscription (preserving prompt-cache coherence on the upstream side), the hook
hashes `session_id` deterministically and rewrites the requested model name to
`<model>-agnes` for ~half of sessions. Each `<model>` therefore has two CRs:

  - modelName `<model>`     → `OPENCODE_MATT_API_KEY`
  - modelName `<model>-agnes` → `OPENCODE_AGNES_API_KEY`

The virtual keys authorize the canonical name only; rewriting happens here in
`async_pre_call_hook`, post-auth and pre-router, so the rewrite is safe.
"""

import hashlib
from typing import Any

from litellm.integrations.custom_logger import CustomLogger

_HEADER = "x-opencode-session"
_AFFINITY_HEADERS = (_HEADER, "x-session-affinity", "x-session-id")
_SESSION_ID = "litellm-headless-services"

# Models that have a parallel `-agnes` deployment behind `OPENCODE_AGNES_API_KEY`.
# Hardcoded on purpose: the proxy has no API to introspect the model list from
# inside a pre-call hook, and the set is small and stable (renovate-managed).
# Keep in sync with `kubernetes/apps/ai/litellm/app/models/opencode-go-agnes/`.
_OPENCODE_GO_MODELS = frozenset(
    {
        "dsv41f",
        "dsv41f-max",
        "dsv41f-nothink",
        "dsv4f",
        "dsv4p",
        "go-dsv4f-vision",
        "go-glm-5.3",
        "go-glm-5.3-flash",
        "go-hy4-preview",
        "go-kimi-k2.7-code",
        "go-kimi-k3",
        "go-minimax-m2.7",
        "go-minimax-m3",
        "go-qwen3.8-flash",
        "go-qwen3.8-max",
        "mimo-v2.5",
        "mimo-v2.5-pro",
        "qwen3.7-plus",
    }
)


def _read_session_id(headers: dict[str, str]) -> str | None:
    lower = {k.lower() for k in headers}
    for target in _AFFINITY_HEADERS:
        if target in lower:
            return next(v for k, v in headers.items() if k.lower() == target)
    return None


def _route_model(session_id: str, model: str) -> str:
    """Pick the deployment modelName for `model` based on a stable hash of
    `session_id`. Same session always returns the same deployment, so an
    openclaw conversation sticks to one OpenCode Go subscription and its
    upstream prompt cache stays coherent.
    """
    if model not in _OPENCODE_GO_MODELS:
        return model
    digest = hashlib.sha256(f"{session_id}:{model}".encode()).digest()
    return f"{model}-agnes" if digest[0] & 1 else model


class ServiceSessionInjector(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: Any,
    ) -> dict:
        headers = dict(data.get("headers") or {})
        session_id = _read_session_id(headers) or _SESSION_ID
        headers.setdefault(_HEADER, session_id)
        model = data.get("model")
        if model:
            data["model"] = _route_model(session_id, model)
        data["headers"] = headers
        return data


service_session_injector = ServiceSessionInjector()
