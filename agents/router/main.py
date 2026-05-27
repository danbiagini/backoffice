"""Hermes Chat router — Cloud Function 2nd gen, Pub/Sub-triggered.

Inspects each inbound Google Chat event on the shared ingress topic, looks up
the sender's email in PARTNER_MAP, and republishes the event verbatim to that
partner's per-partner topic. Each partner's container then pulls from its own
subscription so events stay logically isolated.

Failure modes (all ack to avoid infinite retries):
  - Non-message event (ADDED_TO_SPACE, REMOVED_FROM_SPACE, etc.) → drop silently.
  - Sender email not in PARTNER_MAP → log warning, drop. The Cloud Logging
    entry is the audit trail; no message is delivered.
  - Malformed body / missing sender → log, drop.

Transient errors (target topic 5xx, network) bubble up as exceptions so
Eventarc retries.

Event format: Google Chat publishes Pub/Sub messages with the legacy
"app event" body shape (no Pub/Sub attributes set). Event type lives at
body["type"] ("MESSAGE", "ADDED_TO_SPACE", ...), not in a CloudEvent header.
"""

from __future__ import annotations

import base64
import json
import os

import functions_framework
from cloudevents.http import CloudEvent
from google.cloud import pubsub_v1

PROJECT_ID = os.environ["GOOGLE_CLOUD_PROJECT"]
PARTNER_MAP: dict[str, str] = json.loads(os.environ.get("PARTNER_MAP", "{}"))

# Only MESSAGE events have a clear "owner partner". Drop ADDED_TO_SPACE,
# REMOVED_FROM_SPACE, CARD_CLICKED, etc. — they'd pollute per-partner
# subscriptions with noise and many have no sender in the body at all.
_ROUTABLE_EVENT_TYPES = frozenset({"MESSAGE"})

# All audit output uses print() instead of stdlib logging. functions-framework
# configures its own root logger in CF 2nd gen, which makes logger.info(...)
# calls invisible in Cloud Logging; print(..., flush=True) reliably lands in
# the cloud_run_revision stream.
_publisher = pubsub_v1.PublisherClient()


@functions_framework.cloud_event
def route(cloud_event: CloudEvent) -> None:
    pubsub_message = cloud_event.data["message"]
    raw = pubsub_message.get("data")
    if not raw:
        print("router.empty_body", flush=True)
        return

    try:
        body = json.loads(base64.b64decode(raw))
    except (ValueError, TypeError) as exc:
        print(f"router.decode_failed err={exc}", flush=True)
        return

    event_type = body.get("type", "")
    if event_type not in _ROUTABLE_EVENT_TYPES:
        # Non-routable events (ADDED_TO_SPACE etc.) are common and expected.
        # Silent ack keeps the audit log clean.
        return

    sender_email = (
        body.get("message", {})
        .get("sender", {})
        .get("email", "")
        .strip()
        .lower()
    )

    if not sender_email:
        print(f"router.no_sender type={event_type}", flush=True)
        return

    partner = PARTNER_MAP.get(sender_email)
    if not partner:
        print(f"router.unknown_sender email={sender_email}", flush=True)
        return

    target_topic = f"projects/{PROJECT_ID}/topics/hermes-chat-{partner}"

    future = _publisher.publish(
        target_topic,
        data=base64.b64decode(raw),
    )
    future.result(timeout=10)

    print(f"router.routed email={sender_email} partner={partner}", flush=True)
