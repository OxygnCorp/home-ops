#!/bin/bash
set -euo pipefail

# Incoming arguments
OPENCLAW_GITHUB_WEBHOOK_URL=${1:-}
REPO_FULL_NAME=${2:-}
ISSUE_NUMBER=${3:-}
PR_NUMBER=${4:-}

# Determine the issue/PR number (use whichever is available)
ISSUE_OR_PR_NUMBER="${PR_NUMBER:-${ISSUE_NUMBER:-}}"

# Build the context message
if [[ -n "$ISSUE_OR_PR_NUMBER" && -n "$REPO_FULL_NAME" ]]; then
  CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER - Check new issues or pull request or any new comments on these"
elif [[ -n "$REPO_FULL_NAME" ]]; then
  CONTEXT_MSG="[$REPO_FULL_NAME] - Check new issues or pull request or any new comments on these"
else
  CONTEXT_MSG="Check new issues or pull request or any new comments on these"
fi

# Build the payload to send to OpenClaw
PAYLOAD_JSON=$(jq -n \
  --arg msg "$CONTEXT_MSG" \
  '{
    "message": $msg,
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
