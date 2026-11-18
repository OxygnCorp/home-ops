"""Give every request a stable session identity.

One header, three consumers, and they do not want the same value:

- **Upstream** — OpenCode Go *requires* a stable per-conversation
  `x-opencode-session` header on every request (missing it may error since
  2026-09-06) so it can route a conversation and reuse its prompt cache. The
  header is therefore always injected: the client's own conversation id when it
  sends one (opencode), otherwise a stable per-key value (`litellm-<key_alias>`)
  so each service keeps its own upstream cache bucket. openclaw only emits its
  native header for `opencode.ai` base URLs and its configured headers are
  static, so behind this proxy it is one of the callers that gets the per-key
  value.
- **Observability** — litellm's OTel GenAI mapper exports
  `metadata.session_id` as `gen_ai.conversation.id`, which Phoenix turns into a
  session. A synthetic value there is worse than none: it would collapse every
  conversation of an agent into a single session and, because a Phoenix trace's
  session is fixed by the first span that lands, it would shadow the real
  conversation id carried by the agent's own spans. So only a client-provided
  conversation id is exported.
- **Router** — litellm pins a conversation to one deployment of a model group
  (`optional_pre_call_checks: [session_affinity]`), keyed on
  `metadata.session_id`. Requests that carry no conversation id are pinned per
  virtual key instead (`deployment_affinity`), which keeps the same upstream
  cache coherence without inventing a fake session.

The router only ever narrows the candidate list to deployments that are
currently healthy, so this does not weaken the failover between subscriptions.
"""

import re
from typing import Any

from litellm.integrations.custom_logger import CustomLogger

# If the client sent any of these, that value is its conversation identity.
_HEADERS = ("x-opencode-session", "x-session-affinity", "x-session-id")
_SLUG_RE = re.compile(r"[^A-Za-z0-9._-]+")


def _key_slug(user_api_key_dict: Any) -> str:
    """A stable, human-readable name for the calling virtual key."""
    for attribute in ("key_alias", "team_alias", "user_id"):
        value = getattr(user_api_key_dict, attribute, None)
        if value:
            return _SLUG_RE.sub("-", str(value).lower()).strip("-") or "headless"
    return "headless"


class ServiceSessionInjector(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: Any,
    ) -> dict:
        headers = data.get("headers") or {}
        lowered = {k.lower(): v for k, v in headers.items()}
        client_session = next((lowered[h] for h in _HEADERS if lowered.get(h)), None)

        # Upstream cache identity: the client's own conversation when it has
        # one, otherwise a per-key constant so each service keeps its own
        # upstream cache bucket. This value never reaches observability.
        upstream_session = client_session or f"litellm-{_key_slug(user_api_key_dict)}"
        data["headers"] = {**headers, _HEADERS[0]: upstream_session}

        # Observability and router identity: only a real conversation id. A
        # client that already declared its own session_id in the body keeps it.
        if client_session is not None:
            metadata = data.get("metadata")
            if not isinstance(metadata, dict):
                metadata = {}
                data["metadata"] = metadata
            metadata.setdefault("session_id", client_session)

        return data


service_session_injector = ServiceSessionInjector()
