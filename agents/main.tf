# Per-partner Google Chat Pub/Sub provisioning for Hermes agents.
#
# Scope: ONE partner per `tofu workspace` (or per -var partner=...). Creates
# the isolated cloud resources a single Hermes agent needs to receive Google
# Chat events: a dedicated topic + pull subscription and the two required
# IAM bindings.
#
# No per-partner service account, no key file: Hermes authenticates to
# Pub/Sub via ADC using the GCE instance SA (see ../docs/hermes-clean-runbook.md
# for the rationale). The instance SA is the subscriber on every partner's
# subscription. Tradeoff: GCP-level audit logs don't distinguish partners by
# identity (the subscription name still scopes the log entry to one partner),
# but no long-lived SA keys ever land on disk so
# `iam.disableServiceAccountKeyCreation` stays enforced.
#
# NOT handled here (by design):
#   - The Chat *app* config (name, Pub/Sub connection, visibility) —
#     Console-only, no Terraform/gcloud resource exists. The wrapper prints
#     a reminder.
#   - Container wiring (.env, gateway restart) — done by the wrapper.
#
# State: uses the same GCS bucket as infra/, different prefix, so partner
# applies never touch host/platform state. Use one workspace per partner.

# Partial backend config — bucket/prefix come from `backend.hcl` (gitignored).
# Init with:  tofu init -backend-config=backend.hcl
# See backend.hcl.example for the expected shape. Use the SAME bucket as
# infra/ with a different prefix so partner applies never touch host state.
terraform {
  backend "gcs" {}
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

variable "project" {
  type        = string
  description = "GCP project ID"
}

variable "partner" {
  type        = string
  description = "Short partner identifier, e.g. 'dan'. Used as the resource name prefix."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,28}$", var.partner))
    error_message = "partner must be lowercase alphanumeric/hyphen, starting with a letter (GCP naming rules)."
  }
}

variable "subscriber_sa_email" {
  type        = string
  description = "Email of the GCE instance SA that subscribes via ADC. provision-chat.sh discovers this from the metadata server."
}

provider "google" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-a"
}

locals {
  prefix = "hermes-chat-${var.partner}"
}

# One topic per partner: mirrors the one-bot-per-agent design and avoids
# Pub/Sub filter gymnastics that a shared topic would require.
resource "google_pubsub_topic" "chat" {
  name = local.prefix
}

# Pull subscription — one per partner so each agent receives ONLY its own
# traffic. A shared subscription would load-balance messages across agents
# (cross-partner leak), which is why this must never be shared.
resource "google_pubsub_subscription" "chat" {
  name  = "${local.prefix}-sub"
  topic = google_pubsub_topic.chat.id

  # 7-day retention so a backlog survives a gateway restart / snapshot restore.
  message_retention_duration = "604800s"
  retain_acked_messages      = false

  expiration_policy {
    ttl = "" # never expire (default would delete an idle subscription)
  }
}

# IAM binding #1 — on the TOPIC. The Google Chat push service must be allowed
# to publish events here. THIS IS THE BINDING EVERYONE FORGETS; without it the
# bot connects but silently receives nothing.
# NOTE: this binding is rejected by the iam.allowedPolicyMemberDomains (DRS)
# org policy unless the project has an override. provision-chat.sh prints a
# reminder if onboarding fails on this resource.
resource "google_pubsub_topic_iam_member" "chat_push_publisher" {
  topic  = google_pubsub_topic.chat.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:chat-api-push@system.gserviceaccount.com"
}

# IAM binding #2 — on the SUBSCRIPTION. The GCE instance SA may subscribe...
resource "google_pubsub_subscription_iam_member" "sa_subscriber" {
  subscription = google_pubsub_subscription.chat.id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.subscriber_sa_email}"
}

# ...and may call subscription.get() (Hermes does this at startup as a
# reachability check), which needs Viewer.
resource "google_pubsub_subscription_iam_member" "sa_viewer" {
  subscription = google_pubsub_subscription.chat.id
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${var.subscriber_sa_email}"
}

# Outputs consumed by the wrapper script to write the container .env.
output "topic_id" {
  value = google_pubsub_topic.chat.id
}

output "subscription_name" {
  # Hermes wants the fully-qualified form: projects/<proj>/subscriptions/<name>
  value = "projects/${var.project}/subscriptions/${google_pubsub_subscription.chat.name}"
}

output "chat_app_pubsub_topic" {
  # Paste this into the Console Chat app config → Connection settings → Pub/Sub.
  value = "projects/${var.project}/topics/${google_pubsub_topic.chat.name}"
}
