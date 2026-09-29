"""Inject a stable OpenCode Go session header for headless clients.

OpenCode Go (Console Go) requires a stable per-conversation `x-opencode-session`
for routing and prompt-cache affinity. Agents (openclaw, opencode) always send
one — forwarded as-is. Headless services (memini, lightrag, ...) have no
conversation identity: they get one shared, stable routing identity so their
calls and their litellm router fallbacks onto OpenCode Go succeed.
"""

from typing import Any

from litellm.integrations.custom_logger import CustomLogger

_HEADER = "x-opencode-session"
_SESSION_ID = "litellm-headless-services"


class ServiceSessionInjector(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict: Any,
        cache: Any,
        data: dict,
        call_type: Any,
    ) -> dict:
        headers = data.get("headers") or {}
        lower = {k.lower() for k in headers}
        # Clients carrying their own session identity win; only header-less
        # calls (services) get the shared injected one.
        if not lower & {_HEADER, "x-session-affinity", "x-session-id"}:
            data["headers"] = {**headers, _HEADER: _SESSION_ID}
        return data


service_session_injector = ServiceSessionInjector()
