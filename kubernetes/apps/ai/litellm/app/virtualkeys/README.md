# LiteLLM Virtual Keys

Each file defines a LiteLLM virtual key (`LiteLLMVirtualKey`) plus the `PushSecret` that mirrors it from the cluster Secret into 1Password for consumption by other apps.

## 1Password conventions

All API credentials live in the vault `home-ops`:

- **Category**: items holding API keys/tokens MUST be of type **API Credential** (not "Password"/"Login"). The 1Password Connect API refuses to update or rename items of category `PASSWORD` that have an empty password field (`Password item requires ps value`), which blocks any later automated change.
- **Field naming**: `ABC_DEF` uppercase with underscores (e.g. `MINIMAX_API_KEY`, `KEY_MAINCLAW`), never kebab-case.
- **Centralization**: related keys for the same service are grouped as fields of a single item (e.g. `litellm`) instead of one item per app, and pushed by the `PushSecret` in each `virtualkeys/<app>.yaml` (`remoteKey: litellm`, `property: KEY_<APP>`).
- **Generated items**: `oxygn-dev-tls` — `tls.crt`/`tls.key` exported from cert-manager (`kubernetes/apps/network/certificates/export` push) — must be an **API Credential** item. Historical note: the `kubernetes` item was an old bootstrap kubeconfig holder, no longer referenced anywhere.
- **Sections** in the `litellm` item:
  - `providers` — upstream provider API keys (`MINIMAX_API_KEY`, `OPENCODE_API_KEY`, `ZAI_API_KEY`)
  - `virtual keys` — the per-app virtual key fields (`KEY_*`)
  - `LITELLM_MASTER_KEY` stays at the item root.

## Adding a new virtual key

1. Create `virtualkeys/<app>.yaml` (`LiteLLMVirtualKey` + `PushSecret`) with `property: KEY_<APP>` and add it to `kustomization.yaml`.
2. Nothing to do in 1Password: the `PushSecret` creates the `KEY_<APP>` field in the `litellm` item automatically (first push, ≤1h).
3. The consuming app references it via `remoteRef: { key: litellm, property: KEY_<APP> }`.

## Troubleshooting

- `expected one 1Password ItemField matching 'KEY_*'` → the field was deleted/renamed in 1Password; force the `PushSecret`: `kubectl annotate pushsecret <name> -n ai force-sync=$(date +%s)`
- `SecretSyncedError` on consumers → force refresh: `kubectl annotate externalsecret <name> -n <ns> force-sync=$(date +%s)`
- `Password item requires ps value` (push fails with 400) → the target item is a "Password"-type item; recreate it as **API Credential** (category cannot be changed after creation: copy fields into a new item, delete the old one).
