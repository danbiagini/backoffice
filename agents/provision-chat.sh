#!/usr/bin/env bash
#
# provision-chat.sh — provision Google Chat for one Hermes agent, end to end.
#
# Runs the Terraform (topic, subscription, IAM bindings), then writes the
# Chat config into the partner's Incus container's ~/.hermes/.env and
# restarts the gateway. Finally prints the one manual Console step (Chat
# app config) that has no API.
#
# No per-partner service account, no key file on disk. Hermes authenticates
# to Pub/Sub via ADC using the GCE instance SA (same path as Vertex). The
# instance SA gets Subscriber+Viewer on each partner's subscription. This
# keeps `iam.disableServiceAccountKeyCreation` enforceable.
#
# Idempotent: Terraform converges on re-run, .env upsert wipes prior
# GOOGLE_CHAT_* lines before re-writing.
#
# Usage:
#   ./provision-chat.sh <partner> <allowed-email> <container>
# Example:
#   ./provision-chat.sh dan dan@example.com hermes-dan
#
# Prereqs: must run on the FreeDB host (uses `sudo incus` for container ops
# and queries the GCE metadata server for project ID and instance SA).
# gcloud authed as a project admin; tofu installed; run from this dir; the
# container already cloned from the golden image and running.

set -euo pipefail

PARTNER="${1:?usage: provision-chat.sh <partner> <allowed-email> <container>}"
ALLOWED_EMAIL="${2:?missing allowed-email}"
CONTAINER="${3:?missing container name}"

md() {
  curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/$1" \
    || { echo "ERROR: metadata server unreachable. Run this on the FreeDB host." >&2; exit 1; }
}

echo "==> 1/4  Discovering project and instance SA via metadata server"
PROJECT="$(md project/project-id)"
SUBSCRIBER_SA="$(md instance/service-accounts/default/email)"
echo "    project:     ${PROJECT}"
echo "    instance SA: ${SUBSCRIBER_SA}"

echo "==> 2/4  Terraform: provisioning Chat cloud resources for '${PARTNER}'"
# One workspace per partner so each partner has isolated TF state.
tofu init -input=false -backend-config=backend.hcl >/dev/null
tofu workspace select "$PARTNER" 2>/dev/null || tofu workspace new "$PARTNER"
tofu apply -input=false -auto-approve \
  -var "project=${PROJECT}" \
  -var "partner=${PARTNER}" \
  -var "subscriber_sa_email=${SUBSCRIBER_SA}"

SUB_NAME="$(tofu output -raw subscription_name)"
APP_TOPIC="$(tofu output -raw chat_app_pubsub_topic)"

echo "==> 3/4  Writing Chat config into container ~/.hermes/.env (upsert)"
# Remove any prior GOOGLE_CHAT_* lines, then append fresh ones. No
# GOOGLE_CHAT_SERVICE_ACCOUNT_JSON — Hermes falls back to ADC when unset.
sudo incus exec "$CONTAINER" --user "$(sudo incus exec "$CONTAINER" -- id -u hermes)" \
  --env HOME=/home/hermes -- bash -c "
    set -e
    ENV=/home/hermes/.hermes/.env
    touch \"\$ENV\"
    sed -i '/^GOOGLE_CHAT_/d' \"\$ENV\"
    {
      echo 'GOOGLE_CHAT_PROJECT_ID=${PROJECT}'
      echo 'GOOGLE_CHAT_SUBSCRIPTION_NAME=${SUB_NAME}'
      echo 'GOOGLE_CHAT_ALLOWED_USERS=${ALLOWED_EMAIL}'
    } >> \"\$ENV\"
    chmod 600 \"\$ENV\"
  "

echo "==> 4/4  Restarting gateway to pick up the Chat platform"
sudo incus exec "$CONTAINER" -- systemctl restart hermes-gateway
sleep 3
sudo incus exec "$CONTAINER" -- systemctl is-active hermes-gateway

echo
echo "MANUAL STEP (Console-only, no API):"
cat <<EOF

  Prereq (one-time per project): enable the Chat API. The Configuration page
  below only appears after this:
    gcloud services enable chat.googleapis.com --project=${PROJECT}

  Configure the Chat app in the Cloud Console (one-time per partner):
    https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=${PROJECT}
      • Leave 'Build this Chat app as a Google Workspace add-on' UNCHECKED
        (the Pub/Sub option only appears in the non-add-on flow)
      • App name / avatar / description
      • Interactive features: enable 'Receive 1:1 messages' AND
        'Join spaces and group conversations'
      • Connection settings: Cloud Pub/Sub
          topic = ${APP_TOPIC}
      • Visibility: restrict to your workspace (do NOT publish org-wide)

  Then verify the agent is live:
    1. Open Google Chat → + New Chat → search the app name → send "hello"
       (the bot should reply, proving Chat + Gemini work over the channel)
    2. Watch the connect line:
       sudo incus exec ${CONTAINER} -- journalctl -u hermes-gateway -n 30 --no-pager | grep GoogleChat
       (expect: [GoogleChat] Connected; project=..., subscription=..., bot_user_id=...)

  If the bot connects but never responds: re-check the topic publisher binding
  (chat-api-push@system.gserviceaccount.com must be Pub/Sub Publisher on the topic).
  Terraform creates it, but the Console Chat-app connection above must point at
  the SAME topic. The org policy iam.allowedPolicyMemberDomains (DRS) blocks
  that binding by default — toggle the project-level override during apply.

EOF

echo "Done provisioning Chat for '${PARTNER}' on container '${CONTAINER}'."
