# Mealie

Recipe manager — <https://mealie.oxygn.dev> (external, `envoy-external`). Self-hosted via `ghcr.io/mealie-recipes/mealie`, data on the `mealie` PVC.

## AI integration (litellm)

Mealie works with any OpenAI-compatible API; we use the cluster's litellm gateway. GitOps-wise the
only provisioned artifact is the virtual key (`kubernetes/apps/ai/litellm/app/virtualkeys/mealie.yaml`
→ `Secret/litellm-key-mealie`, mirrored to 1Password as `litellm/KEY_MEALIE`).

### Provider configuration (Group Settings UI, per-group — stored in the app DB, not Git)

1. Read the key: `just kube view-secret ai litellm-key-mealie`
2. In Mealie go to **Group Settings → AI** and configure:
   - **Default provider**: base URL `http://litellm.ai:4000/v1`, the key above, model `dsv41f`.
     Unlocks the AI ingredient parser, the URL-import AI fallback, and the *Import with AI* page
     (pasted text/HTML/JSON, or photos — v3.23+).
   - **Image provider**: same credentials, model `dsv41f` (`supportsVision: true`) — enables recipe
     creation from photos.
   - **Audio provider**: intentionally not configured for now (no whisper-type model behind litellm).

Features requiring ≥ v3.30: per-task custom prompts (Group Settings → AI).

Reference: <https://mealie.io/documentation/getting-started/installation/ai-providers/>
