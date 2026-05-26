#!/usr/bin/env bash
#
# provision-chat.sh — provision Google Chat for one Hermes agent, end to end.
#
# Runs the Terraform (SA, topic, subscription, IAM), then does the parts that
# don't belong in TF state: generates the SA key with gcloud, pushes it into
# the partner's Incus container, writes the Chat config into the container's
# ~/.hermes/.env, and restarts the gateway. Finally prints the one manual
# Console step (Chat app config) that has no API.
#
# Idempotent-ish: Terraform converges on re-run; the key step creates a NEW key
# each run (gcloud has no "create if absent"), so re-running rotates the key —
# see the guard below. The .env write is upsert (removes old GOOGLE_CHAT_* lines
# first), so re-running is safe.
#
# Usage:
#   ./provision-chat.sh <partner> <allowed-email> <container>
# Example:
#   ./provision-chat.sh dan dan@example.com hermes-dan
#
# Prereqs: gcloud authed as a project admin; tofu installed; run from this dir;
# the container already cloned from the golden image and running.

set -euo pipefail

PARTNER="${1:?usage: PROJECT=<gcp-project-id> provision-chat.sh <partner> <allowed-email> <container>}"
ALLOWED_EMAIL="${2:?missing allowed-email}"
CONTAINER="${3:?missing container name}"

# GCP project — export before running, e.g.  export PROJECT=acme-corp-123456
: "${PROJECT:?must export PROJECT=<your-gcp-project-id> before running}"
PREFIX="hermes-chat-${PARTNER}"
SA_EMAIL="${PREFIX}@${PROJECT}.iam.gserviceaccount.com"

# Where the key lands inside the container (per-partner layer-2 secret).
CONTAINER_KEY_PATH="/home/hermes/.hermes/google-chat-sa.json"
# Temp path on the host before we push it in; cleaned up after.
TMP_KEY="$(mktemp /tmp/${PREFIX}-key.XXXXXX.json)"
trap 'rm -f "$TMP_KEY"' EXIT

echo "==> 1/6  Terraform: provisioning Chat cloud resources for '${PARTNER}'"
# One workspace per partner so each partner has isolated TF state.
tofu init -input=false -backend-config=backend.hcl >/dev/null
tofu workspace select "$PARTNER" 2>/dev/null || tofu workspace new "$PARTNER"
tofu apply -input=false -auto-approve \
  -var "project=${PROJECT}" \
  -var "partner=${PARTNER}"

SUB_NAME="$(tofu output -raw subscription_name)"
APP_TOPIC="$(tofu output -raw chat_app_pubsub_topic)"

echo "==> 2/6  Generating SA key (outside TF state)"
# gcloud can't "create if absent"; guard against piling up keys on re-run.
EXISTING_KEYS="$(gcloud iam service-accounts keys list \
  --iam-account="$SA_EMAIL" --managed-by=user \
  --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$EXISTING_KEYS" -gt 0 ]; then
  echo "    NOTE: ${EXISTING_KEYS} user-managed key(s) already exist for ${SA_EMAIL}."
  echo "    Creating a new one anyway (re-run rotates the key). Old keys remain"
  echo "    valid until you delete them: gcloud iam service-accounts keys delete ..."
fi
gcloud iam service-accounts keys create "$TMP_KEY" \
  --iam-account="$SA_EMAIL" >/dev/null
echo "    key created"

echo "==> 3/6  Pushing key into container '${CONTAINER}'"
sudo incus file push "$TMP_KEY" "${CONTAINER}${CONTAINER_KEY_PATH}"
sudo incus exec "$CONTAINER" -- chown hermes:hermes "$CONTAINER_KEY_PATH"
sudo incus exec "$CONTAINER" -- chmod 600 "$CONTAINER_KEY_PATH"

echo "==> 4/6  Writing Chat config into container ~/.hermes/.env (upsert)"
# Remove any prior GOOGLE_CHAT_* lines, then append fresh ones. Done inside the
# container as the hermes user so ownership stays correct.
sudo incus exec "$CONTAINER" --user "$(sudo incus exec "$CONTAINER" -- id -u hermes)" \
  --env HOME=/home/hermes -- bash -c "
    set -e
    ENV=/home/hermes/.hermes/.env
    touch \"\$ENV\"
    sed -i '/^GOOGLE_CHAT_/d' \"\$ENV\"
    {
      echo 'GOOGLE_CHAT_PROJECT_ID=${PROJECT}'
      echo 'GOOGLE_CHAT_SUBSCRIPTION_NAME=${SUB_NAME}'
      echo 'GOOGLE_CHAT_SERVICE_ACCOUNT_JSON=${CONTAINER_KEY_PATH}'
      echo 'GOOGLE_CHAT_ALLOWED_USERS=${ALLOWED_EMAIL}'
    } >> \"\$ENV\"
    chmod 600 \"\$ENV\"
  "

echo "==> 5/6  Restarting gateway to pick up the Chat platform"
sudo incus exec "$CONTAINER" -- systemctl restart hermes-gateway
sleep 3
sudo incus exec "$CONTAINER" -- systemctl is-active hermes-gateway

echo "==> 6/6  MANUAL STEP (Console-only, no API):"
cat <<EOF

  Configure the Chat app in the Cloud Console (one-time per partner):
    Console → APIs & Services → Google Chat API → Configuration
      • App name / avatar / description
      • Functionality: enable 'Receive 1:1 messages' AND
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
  the SAME topic.

EOF

echo "Done provisioning Chat for '${PARTNER}' on container '${CONTAINER}'."
