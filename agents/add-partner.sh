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
#        ./add-partner.sh <partner> <allowed-email> <container>
#
# This script only handles the container side: writes ~/.hermes/.env and
# restarts the gateway. Must run on the FreeDB host (uses sudo incus + the
# GCE metadata server for the project ID).
#
# Idempotent: the .env upsert wipes prior GOOGLE_CHAT_* lines before
# re-writing, so re-running is safe.

set -euo pipefail

PARTNER="${1:?usage: add-partner.sh <partner> <allowed-email> <container>}"
ALLOWED_EMAIL="${2:?missing allowed-email}"
CONTAINER="${3:?missing container name}"

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

echo "==> 2/3  Writing Chat config into container ~/.hermes/.env (upsert)"
# Remove any prior GOOGLE_CHAT_* lines, then append fresh ones. No
# GOOGLE_CHAT_SERVICE_ACCOUNT_JSON — Hermes uses ADC via the instance SA.
# GOOGLE_CHAT_ALLOWED_USERS is defense in depth: the router already filters
# by sender email, but Hermes drops messages from anyone outside this list
# even if the router misroutes.
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

echo "==> 3/3  Restarting gateway to pick up the Chat platform"
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

EOF
