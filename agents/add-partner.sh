#!/usr/bin/env bash
#
# add-partner.sh — wire a partner's Incus container to the muxed Chat plumbing.
#
# The cloud-side resources (ingress topic, router CF, per-partner topic+sub,
# IAM) are managed by Terraform in this directory. Adding a partner:
#
#   1. Add an entry to var.partner_map in your local backoffice.tfvars:
#        partner_map = {
#          "dan@example.com" = "dan"
#        }
#   2. Run: tofu apply -var-file=backoffice.tfvars
#      (creates that partner's topic+sub and refreshes the router's mapping)
#   3. Run THIS script to wire the container side:
#        ./add-partner.sh <partner> <allowed-email> <container> [client_secret_path]
#
# This script handles the container side: writes ~/.hermes/.env, enables the
# google_chat platform, restarts the gateway, and (optionally) pushes a
# Google Workspace OAuth client_secret.json into ~/.hermes/. Must run on the
# host (uses sudo incus + the GCE metadata server for the project ID).
#
# The 4th arg (client_secret_path) is optional. When provided, the file is
# pushed to /home/hermes/.hermes/client_secret.json (chmod 600, owned by
# hermes). If omitted, the script auto-detects ~/hermes-client-secret.json
# on the host. If neither exists, Workspace OAuth setup is skipped — Chat
# still works without it; the partner can add it later by re-running this
# script with the 4th arg, or by manually pushing the file.
#
# Idempotent: the .env upsert wipes prior GOOGLE_CHAT_* lines before
# re-writing, so re-running is safe. The client_secret push overwrites
# whatever was there before.

set -euo pipefail

PARTNER="${1:?usage: add-partner.sh <partner> <allowed-email> <container> [client_secret_path]}"
ALLOWED_EMAIL="${2:?missing allowed-email}"
CONTAINER="${3:?missing container name}"
CLIENT_SECRET="${4:-$HOME/hermes-client-secret.json}"

md() {
  curl -fsS --max-time 3 -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/$1" \
    || { echo "ERROR: metadata server unreachable. Run this on the FreeDB host." >&2; exit 1; }
}

echo "==> 1/3  Discovering project via metadata server"
PROJECT="$(md project/project-id)"
SUB_NAME="projects/${PROJECT}/subscriptions/hermes-chat-${PARTNER}-sub"
echo "    project:      ${PROJECT}"
echo "    subscription: ${SUB_NAME}"

HERMES_UID="$(sudo incus exec "$CONTAINER" -- id -u hermes)"

echo "==> 2/4  Writing Chat config into container ~/.hermes/.env (upsert)"
# Remove any prior GOOGLE_CHAT_* lines, then append fresh ones. No
# GOOGLE_CHAT_SERVICE_ACCOUNT_JSON — Hermes uses ADC via the instance SA.
# GOOGLE_CHAT_ALLOWED_USERS is defense in depth: the router already filters
# by sender email, but Hermes drops messages from anyone outside this list
# even if the router misroutes.
sudo incus exec "$CONTAINER" --user "$HERMES_UID" \
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

echo "==> 3/4  Enabling google_chat platform in Hermes config (idempotent)"
# Golden ships with the gateway idle (no platforms in config.yaml). Activation
# happens here so each partner's clone goes from idle → live in one step.
# `hermes config set` is idempotent; re-running this script is safe.
sudo incus exec "$CONTAINER" --user "$HERMES_UID" \
  --env HOME=/home/hermes -- \
  /home/hermes/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main \
    config set platforms.google_chat.enabled true

echo "==> 4/5  Pushing Workspace OAuth client_secret.json (optional)"
HERMES_GID="$(sudo incus exec "$CONTAINER" -- id -g hermes)"
if [[ -f "$CLIENT_SECRET" ]]; then
  sudo incus file push "$CLIENT_SECRET" \
    "${CONTAINER}/home/hermes/.hermes/client_secret.json" \
    --uid="$HERMES_UID" --gid="$HERMES_GID" --mode=0600
  CLIENT_SECRET_PRESENT=1
  echo "    pushed:       ${CLIENT_SECRET} -> /home/hermes/.hermes/client_secret.json"
else
  CLIENT_SECRET_PRESENT=0
  echo "    skipped:      no file at ${CLIENT_SECRET} (Workspace OAuth not configured for this partner)"
fi

echo "==> 5/5  Restarting gateway to pick up the Chat platform"
sudo incus exec "$CONTAINER" -- systemctl restart hermes-gateway
sleep 3
sudo incus exec "$CONTAINER" -- systemctl is-active hermes-gateway

cat <<EOF

Done. Container '${CONTAINER}' now subscribes to ${SUB_NAME}.

The router decides whether this container actually receives messages based
on var.partner_map entries from the most recent tofu apply. If you haven't
added '${ALLOWED_EMAIL}' → '${PARTNER}' to the map yet, do that and re-apply
or the bot will drop every event from that user as 'router.unknown_sender'
(visible in the Cloud Function's logs).

Test path:
  - DM the bot from ${ALLOWED_EMAIL}
  - Watch CF logs: gcloud functions logs read hermes-chat-router --gen2 --region=us-central1
    (expect: router.routed email=${ALLOWED_EMAIL} partner=${PARTNER})
  - Watch container: sudo incus exec ${CONTAINER} -- journalctl -u hermes-gateway -n 30 --no-pager | grep GoogleChat

Tell ${ALLOWED_EMAIL} on their first DM with the bot:
  1. They will see a "📬 No home channel is set" prompt before the real reply.
  2. Type /sethome in the DM to pin it as their cron/notification destination.
  3. Subsequent messages get a direct reply with no prompt.
$( if [[ "${CLIENT_SECRET_PRESENT}" == "1" ]]; then cat <<INNER

For Google Workspace integration (Gmail / Calendar / Drive), tell ${ALLOWED_EMAIL}:
  - DM Hermes: "set up google workspace"
  - When asked for the OAuth credential path, paste:
      /home/hermes/.hermes/client_secret.json
  - Approve the browser consent as their own Workspace account.
  - The resulting token lands at ~/.hermes/google_token.json — per-partner,
    no one else can use it.
INNER
fi)

EOF
