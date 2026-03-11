#!/bin/bash
set -euo pipefail

# Incoming arguments
OPENCLAW_GITHUB_WEBHOOK_URL=${1:-}
REPO_FULL_NAME=${2:-}
ISSUE_NUMBER=${3:-}
PR_NUMBER=${4:-}
GITHUB_EVENT=${5:-}

# Determine the issue/PR number and type
if [[ -n "$PR_NUMBER" ]]; then
  ISSUE_OR_PR_NUMBER="$PR_NUMBER"
  ISSUE_OR_PR_TYPE="PR"
elif [[ -n "$ISSUE_NUMBER" ]]; then
  ISSUE_OR_PR_NUMBER="$ISSUE_NUMBER"
  ISSUE_OR_PR_TYPE="Issue"
fi

# Build specific message based on event type
case "$GITHUB_EVENT" in
  issues)
    CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER (Issue opened/assigned)"
    ;;
  issue_comment)
    CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER (New comment on Issue)"
    ;;
  pull_request)
    CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER (PR event)"
    ;;
  pull_request_review)
    CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER (PR review)"
    ;;
  *)
    if [[ -n "$ISSUE_OR_PR_NUMBER" && -n "$REPO_FULL_NAME" && -n "$ISSUE_OR_PR_TYPE" ]]; then
      CONTEXT_MSG="[$REPO_FULL_NAME] #$ISSUE_OR_PR_NUMBER ($ISSUE_OR_PR_TYPE)"
    elif [[ -n "$REPO_FULL_NAME" ]]; then
      CONTEXT_MSG="[$REPO_FULL_NAME] - $GITHUB_EVENT event"
    else
      CONTEXT_MSG="Check new issues or pull request or any new comments on these"
    fi
    ;;
esac

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
