"""Give every request a stable session identity.

Two consumers, one value:

- **Upstream** — OpenCode Go (Console Go) wants a stable per-conversation
  `x-opencode-session` header for its own prompt cache. Agents (openclaw,
  opencode) always send one and it is forwarded as-is. Headless services
  (memini, lightrag, ...) have no conversation identity, so they get one shared
  value; the header is still injected so their calls behave upstream.
- **Router** — litellm pins a conversation to one deployment of a model group
  (`optional_pre_call_checks: [session_affinity]`), keyed on
  `metadata.session_id`. Without it, `simple-shuffle` re-rolls the dice on
  every request and a session alternates between the two OpenCode Go
  subscriptions, splitting its upstream cache in half.

The router only ever narrows the candidate list to deployments that are
currently healthy, so this does not weaken the failover between subscriptions.
"""

from typing import Any

from litellm.integrations.custom_logger import CustomLogger

# If the client sent any of these, that value is its conversation identity.
_HEADERS = ("x-opencode-session", "x-session-affinity", "x-session-id")
_FALLBACK = "litellm-headless-services"


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

        session_id = next((lowered[h] for h in _HEADERS if lowered.get(h)), None)
        if session_id is None:
            # Header-less call (a headless service): give it a stable identity
            # rather than letting every request land on a different deployment.
            session_id = _FALLBACK
            data["headers"] = {**headers, _HEADERS[0]: session_id}

        # Router-side affinity. A client that already declared its own
        # session_id in the body keeps it.
        metadata = data.get("metadata")
        if not isinstance(metadata, dict):
            metadata = {}
            data["metadata"] = metadata
        metadata.setdefault("session_id", session_id)

        return data


service_session_injector = ServiceSessionInjector()
