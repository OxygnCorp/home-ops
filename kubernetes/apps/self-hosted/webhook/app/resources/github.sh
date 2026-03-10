#!/bin/bash
set -euo pipefail

# Incoming arguments
OPENCLAW_GITHUB_WEBHOOK_URL=${1:-}

# Build the payload to send to OpenClaw
PAYLOAD_JSON=$(jq -n \
  '{
    "message": "Check new issues or pull request or any new comments on these",
    "name": "Github",
    "agentId": "devops",
    "wakeMode": "now",
    "deliver": true,
    "channel": "discord",
    "thinking": "low",
    "timeoutSeconds": 120
  }')

curl -s -X POST \
  "${OPENCLAW_GITHUB_WEBHOOK_URL}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENCLAW_WEBHOOK_TOKEN" \
  -d "$PAYLOAD_JSON"
