#!/bin/bash
set -euo pipefail

# Script appelé par webhook pour notifier OpenClaw des événements GitHub
# Reçoit le payload JSON complet en argument et les headers via variables d'environnement

OPENCLAW_WEBHOOK_URL="${1:-}"
PAYLOAD="${2:-}"
GITHUB_EVENT="${GITHUB_EVENT:-}"
X_GITHUB_DELIVERY="${X_GITHUB_DELIVERY:-}"

# Vérifier que c'est du JSON valide
if ! echo "$PAYLOAD" | jq -e . >/dev/null 2>&1; then
    echo "ERROR: Invalid JSON payload" >&2
    exit 1
fi

# Extraire les informations du repository
REPO_FULL_NAME=$(echo "$PAYLOAD" | jq -r '.repository.full_name // .repository.name // "unknown"')

# Déterminer le type d'événement (issue, PR ou review) et extraire les données
IS_PR=false
PR_URL=$(echo "$PAYLOAD" | jq -r '.issue.pull_request.url // .pull_request.url // ""')
if [[ "$PR_URL" != "null" && -n "$PR_URL" ]]; then
    IS_PR=true
    EVENT_TYPE="pull_request"
elif [[ "$GITHUB_EVENT" == "pull_request" || "$GITHUB_EVENT" == "pull_request_review" ]]; then
    IS_PR=true
    EVENT_TYPE="$GITHUB_EVENT"
else
    EVENT_TYPE="issue"
fi

# Extraire le numéro et les détails selon le type
if [[ "$IS_PR" == "true" && "$EVENT_TYPE" == "pull_request" ]]; then
    NUMBER=$(echo "$PAYLOAD" | jq -r '.pull_request.number // .number // ""')
    TITLE=$(echo "$PAYLOAD" | jq -r '.pull_request.title // ""')
    BODY=$(echo "$PAYLOAD" | jq -r '.pull_request.body // ""')
    STATE=$(echo "$PAYLOAD" | jq -r '.pull_request.state // ""')
    USER=$(echo "$PAYLOAD" | jq -r '.pull_request.user.login // ""')
    ASSIGNEE=$(echo "$PAYLOAD" | jq -r '.pull_request.assignee.login // ""')
    ACTION=$(echo "$PAYLOAD" | jq -r '.action // ""')
elif [[ "$EVENT_TYPE" == "pull_request_review" ]]; then
    NUMBER=$(echo "$PAYLOAD" | jq -r '.pull_request.number // .number // ""')
    TITLE=$(echo "$PAYLOAD" | jq -r '.pull_request.title // ""')
    BODY=$(echo "$PAYLOAD" | jq -r '.review.body // ""')
    USER=$(echo "$PAYLOAD" | jq -r '.review.user.login // ""')
    REVIEW_STATE=$(echo "$PAYLOAD" | jq -r '.review.state // ""')
    ACTION=$(echo "$PAYLOAD" | jq -r '.action // ""')
else
    # Issue
    NUMBER=$(echo "$PAYLOAD" | jq -r '.issue.number // .number // ""')
    TITLE=$(echo "$PAYLOAD" | jq -r '.issue.title // ""')
    BODY=$(echo "$PAYLOAD" | jq -r '.issue.body // ""')
    STATE=$(echo "$PAYLOAD" | jq -r '.issue.state // ""')
    USER=$(echo "$PAYLOAD" | jq -r '.issue.user.login // ""')
    ASSIGNEE=$(echo "$PAYLOAD" | jq -r '.issue.assignee.login // ""')
    ACTION=$(echo "$PAYLOAD" | jq -r '.action // ""')
fi

# Extraire le commentaire si présent
COMMENT_BODY=$(echo "$PAYLOAD" | jq -r '.comment.body // ""')
COMMENT_USER=$(echo "$PAYLOAD" | jq -r '.comment.user.login // ""')

# Sender (qui a déclenché l'événement)
SENDER=$(echo "$PAYLOAD" | jq -r '.sender.login // ""')

# Construire le message contextuel enrichi
case "${EVENT_TYPE}_${ACTION}" in
    "issue_opened")
        EVENT_DESC="Nouvelle issue créée"
        ;;
    "issue_assigned")
        EVENT_DESC="Issue assignée"
        ;;
    "issue_reopened")
        EVENT_DESC="Issue réouverte"
        ;;
    "issue_closed")
        EVENT_DESC="Issue fermée"
        ;;
    "pull_request_opened")
        EVENT_DESC="Nouvelle Pull Request"
        ;;
    "pull_request_assigned")
        EVENT_DESC="PR assignée"
        ;;
    "pull_request_synchronize")
        EVENT_DESC="Nouveaux commits poussés"
        ;;
    "pull_request_reopened")
        EVENT_DESC="PR rouverte"
        ;;
    "pull_request_closed")
        EVENT_DESC="PR fermée"
        ;;
    "pull_request_review_submitted")
        EVENT_DESC="Review soumise"
        ;;
    *)
        EVENT_DESC="Événement: ${EVENT_TYPE} - ${ACTION}"
        ;;
esac

# Construire le message complet
CONTEXT_MSG="[$REPO_FULL_NAME] #$NUMBER"

if [[ -n "$EVENT_DESC" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG} - ${EVENT_DESC}"
fi

# Ajouter le titre si disponible
if [[ -n "$TITLE" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}

Titre: ${TITLE}"
fi

# Ajouter le body (tronqué si trop long)
if [[ -n "$BODY" && "$BODY" != "null" ]]; then
    BODY_TRUNCATED=$(echo "$BODY" | head -c 1500)
    CONTEXT_MSG="${CONTEXT_MSG}

Description:
${BODY_TRUNCATED}"
fi

# Ajouter le commentaire
if [[ -n "$COMMENT_BODY" && "$COMMENT_BODY" != "null" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}

Commentaire de ${COMMENT_USER}:
${COMMENT_BODY}"
fi

# Ajouter les infos de contexte
if [[ -n "$USER" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}

Auteur: ${USER}"
fi

if [[ -n "$SENDER" && "$SENDER" != "$USER" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}
Déclenché par: ${SENDER}"
fi

if [[ -n "$ASSIGNEE" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}
Assigné à: ${ASSIGNEE}"
fi

if [[ "$EVENT_TYPE" == "pull_request_review" && -n "$REVIEW_STATE" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}
Review: ${REVIEW_STATE}"
fi

# Ajouter le delivery ID pour le suivi
if [[ -n "$X_GITHUB_DELIVERY" ]]; then
    CONTEXT_MSG="${CONTEXT_MSG}

Event ID: ${X_GITHUB_DELIVERY}"
fi

# ============================================================
# Pour les événements PR (pull_request), orienter vers lobster
# ============================================================
# Si c'est un PR (pas un review), on envoie un message directive pour lobster
# avec deliver=false pour que l'agent isolé exécute le pipeline

if [[ "$IS_PR" == "true" && "$EVENT_TYPE" == "pull_request" ]]; then
    LOBSTER_MSG="PR #$NUMBER - $REPO_FULL_NAME

Run lobster pipeline: lobster run --file ~/.openclaw/workspace/projects/openclaw-automatisation/pipelines/devops-pr-gate.lobster --args-json '{\"PR\":$NUMBER,\"REPO\":\"$REPO_FULL_NAME\"}'

PR Title: $TITLE
PR Author: $USER
PR Action: $ACTION"

    # Payload pour PR - directive lobster, deliver=false
    PAYLOAD_JSON=$(jq -n \
        --arg msg "$LOBSTER_MSG" \
        --arg repo "$REPO_FULL_NAME" \
        --arg number "$NUMBER" \
        --arg type "$EVENT_TYPE" \
        --arg action "$ACTION" \
        --arg title "$TITLE" \
        --arg sender "$SENDER" \
        --arg assignee "$ASSIGNEE" \
        '{
            "message": $msg,
            "name": "GitHub",
            "agentId": "devops",
            "wakeMode": "now",
            "deliver": false,
            "channel": "discord",
            "thinking": "medium",
            "timeoutSeconds": 300,
            "metadata": {
                "repository": $repo,
                "number": $number,
                "type": $type,
                "action": $action,
                "title": $title,
                "sender": $sender,
                "assignee": $assignee
            }
        }')

    echo "Sending PR to lobster pipeline: $REPO_FULL_NAME #$NUMBER" >&2
else
    # Pour les issues et reviews, garder le comportement actuel (deliver=true)
    PAYLOAD_JSON=$(jq -n \
        --arg msg "$CONTEXT_MSG" \
        --arg repo "$REPO_FULL_NAME" \
        --arg number "$NUMBER" \
        --arg type "$EVENT_TYPE" \
        --arg action "$ACTION" \
        --arg title "$TITLE" \
        --arg sender "$SENDER" \
        --arg assignee "$ASSIGNEE" \
        '{
            "message": $msg,
            "name": "GitHub",
            "agentId": "devops",
            "wakeMode": "now",
            "deliver": true,
            "channel": "discord",
            "thinking": "medium",
            "timeoutSeconds": 300,
            "metadata": {
                "repository": $repo,
                "number": $number,
                "type": $type,
                "action": $action,
                "title": $title,
                "sender": $sender,
                "assignee": $assignee
            }
        }')

    echo "Sending to OpenClaw: $EVENT_TYPE $ACTION on $REPO_FULL_NAME #$NUMBER" >&2
fi

# Envoyer à OpenClaw
curl -s -X POST \
    "${OPENCLAW_WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $OPENCLAW_WEBHOOK_TOKEN" \
    -d "$PAYLOAD_JSON"

echo "Webhook dispatched for $REPO_FULL_NAME #$NUMBER" >&2
