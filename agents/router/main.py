"""Hermes Chat router — Cloud Function 2nd gen, Pub/Sub-triggered.

Inspects each inbound Google Chat event on the shared ingress topic, looks up
the sender's email in PARTNER_MAP, and republishes the event verbatim to that
partner's per-partner topic. Each partner's container then pulls from its own
subscription so events stay logically isolated.

Failure modes (all ack to avoid infinite retries):
  - Non-message event (edit, delete, reaction, membership) → drop silently.
  - Sender email not in PARTNER_MAP → log warning, drop. The Cloud Logging
    entry is the audit trail; no message is delivered.
  - Malformed body / missing sender → log, drop.

Transient errors (target topic 5xx, network) bubble up as exceptions so
Eventarc retries.
"""

from __future__ import annotations

import base64
import json
import logging
import os

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import pubsub_v1

PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
PARTNER_MAP: dict[str, str] = json.loads(os.environ.get("PARTNER_MAP", "{}"))

# Only message-created events have a clear "owner partner". Drop edits,
# deletes, reactions, and membership changes — they'd pollute per-partner
# subscriptions with noise (and many have no sender in the body at all).
_ROUTABLE_CE_TYPES = frozenset(
    {"google.workspace.chat.message.v1.created"}
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hermes-chat-router")

_publisher = pubsub_v1.PublisherClient()


@functions_framework.cloud_event
def route(cloud_event: CloudEvent) -> None:
    pubsub_message = cloud_event.data["message"]
    attributes = pubsub_message.get("attributes") or {}
    ce_type = attributes.get("ce-type", "")

    if ce_type not in _ROUTABLE_CE_TYPES:
        # Quiet path — these are common and expected (every reaction fires one).
        return

    raw = pubsub_message.get("data")
    if not raw:
        logger.warning("router.empty_body ce-type=%s", ce_type)
        return

    try:
        body = json.loads(base64.b64decode(raw))
    except (ValueError, TypeError) as exc:
        logger.warning("router.decode_failed ce-type=%s err=%s", ce_type, exc)
        return

    sender_email = (
        body.get("message", {})
        .get("sender", {})
        .get("email", "")
        .strip()
        .lower()
    )

    if not sender_email:
        logger.warning(
            "router.no_sender ce-type=%s body_keys=%s",
            ce_type,
            list(body.keys()),
        )
        return

    partner = PARTNER_MAP.get(sender_email)
    if not partner:
        # Unknown sender — drop with an audit log. Add to var.partner_map if
        # they should be reaching a bot.
        logger.warning("router.unknown_sender email=%s", sender_email)
        return

    target_topic = f"projects/{PROJECT_ID}/topics/hermes-chat-{partner}"

    # Forward the event verbatim — preserve the CloudEvents-style attributes
    # (ce-id, ce-source, ce-subject, ce-time, ce-type) so the downstream
    # Hermes container sees the same envelope Chat originally published.
    future = _publisher.publish(
        target_topic,
        data=base64.b64decode(raw),
        **attributes,
    )
    future.result(timeout=10)

    logger.info("router.routed email=%s partner=%s", sender_email, partner)
