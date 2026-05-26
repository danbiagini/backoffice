# Per-partner Google Chat Pub/Sub provisioning for Hermes agents.
#
# Scope: ONE partner per `tofu workspace` (or per -var partner=...). Creates the
# isolated cloud resources a single Hermes agent needs to receive Google Chat
# events: a dedicated service account, a Pub/Sub topic + pull subscription, and
# the two IAM bindings. Each partner gets their own set so a leaked credential
# reaches only that partner's chat stream.
#
# NOT handled here (by design):
#   - The SA *key file* — keys in TF state are an anti-pattern. The wrapper
#     script (provision-chat.sh) generates the key with gcloud, outside state.
#   - The Chat *app* config (name, Pub/Sub connection, visibility) — Console-only,
#     no Terraform/gcloud resource exists. The wrapper prints a reminder.
#   - Container wiring (.env, gateway restart) — done by the wrapper.
#
# State: uses the same GCS bucket as infra/, different prefix, so partner applies
# never touch host/platform state. Use one workspace per partner.

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

provider "google" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-a"
}

locals {
  prefix = "hermes-chat-${var.partner}"
}

# Dedicated SA for THIS partner's agent. No project-level roles — its only
# authority is Subscriber+Viewer on its own subscription (granted below).
resource "google_service_account" "chat" {
  account_id   = local.prefix
  display_name = "Hermes Chat bot — ${var.partner}"
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
resource "google_pubsub_topic_iam_member" "chat_push_publisher" {
  topic  = google_pubsub_topic.chat.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:chat-api-push@system.gserviceaccount.com"
}

# IAM binding #2 — on the SUBSCRIPTION. Our partner SA may subscribe...
resource "google_pubsub_subscription_iam_member" "sa_subscriber" {
  subscription = google_pubsub_subscription.chat.id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.chat.email}"
}

# ...and may call subscription.get() (Hermes does this at startup as a
# reachability check), which needs Viewer.
resource "google_pubsub_subscription_iam_member" "sa_viewer" {
  subscription = google_pubsub_subscription.chat.id
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${google_service_account.chat.email}"
}

# Outputs consumed by the wrapper script to write the container .env.
output "service_account_email" {
  value = google_service_account.chat.email
}

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
