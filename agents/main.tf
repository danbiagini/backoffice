# Muxed Google Chat plumbing for Hermes agents.
#
# Architecture: ONE shared Chat app (per GCP project — Google's hard limit)
# publishes every event to a single ingress topic. A Cloud Function inspects
# each event, looks up the sender in var.partner_map, and republishes to that
# partner's dedicated topic. Each Hermes container subscribes only to its own
# per-partner subscription so events stay logically isolated.
#
# Scope: ONE module covers all partners. Drive new partners by editing
# var.partner_map and re-applying — no workspaces, no per-partner setup
# beyond a .env tweak in the container (handled by ./add-partner.sh).
#
# What this gives you:
#   - Per-partner data isolation at the subscription layer
#   - One Chat app to configure once (vs. one project per partner — doesn't scale)
#   - Adding a partner = one map entry + tofu apply
#
# What this intentionally does NOT do:
#   - Per-partner IAM enforcement (layer-2). The instance SA is the subscriber
#     on EVERY per-partner subscription, so a misconfigured/compromised container
#     could in principle subscribe to another partner's stream. The router gives
#     logical routing, not IAM isolation. Acceptable for three trusting co-founders;
#     migrate to per-partner SAs via impersonation (small Hermes patch) before
#     opening this up beyond that.
#   - Chat app config (name, avatar, Pub/Sub destination, visibility) — Console-only,
#     no API exists. The add-partner script prints the Console URL to switch the
#     destination to the ingress topic.
#   - Container wiring (.env, gateway restart) — done by ./add-partner.sh.

# Partial backend config — bucket/prefix come from `backend.hcl` (gitignored).
# Init with:  tofu init -backend-config=backend.hcl
terraform {
  backend "gcs" {}
  required_providers {
    google = {
      source = "hashicorp/google"
    }
    archive = {
      source = "hashicorp/archive"
    }
  }
}

variable "project" {
  type        = string
  description = "GCP project ID."
}

variable "partner_map" {
  type        = map(string)
  description = <<-EOT
    Map of Workspace email -> short partner ID. Drives both per-partner topic
    creation and the Cloud Function's routing table.

    Example:
      partner_map = {
        "dan@example.com"   = "dan"
        "alice@example.com" = "alice"
      }

    Constraints:
      - Email keys must be lowercase and match exactly the address Chat reports
        in `message.sender.email` (Workspace email, not personal aliases).
      - Partner IDs must satisfy GCP resource-naming rules (lowercase alnum +
        hyphen, starts with a letter, <= 28 chars).
  EOT

  validation {
    condition = alltrue([
      for partner in values(var.partner_map) :
      can(regex("^[a-z][a-z0-9-]{1,28}$", partner))
    ])
    error_message = "Each partner ID must be lowercase alphanumeric/hyphen, starting with a letter (GCP naming rules)."
  }
}

variable "subscriber_sa_email" {
  type        = string
  description = "Email of the GCE instance SA that subscribes via ADC. add-partner.sh discovers this from the metadata server."
}

provider "google" {
  project = var.project
  region  = "us-central1"
  zone    = "us-central1-a"
}

data "google_project" "current" {}

# ---------------------------------------------------------------------------
# Ingress: single topic the shared Chat app publishes to.
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "ingress" {
  name = "hermes-chat-ingress"
}

# THE BINDING EVERYONE FORGETS. Google's Chat infra publishes events as
# chat-api-push@system.gserviceaccount.com — it needs Publisher on the topic
# the Chat app is configured to use. Blocked by the iam.allowedPolicyMemberDomains
# (Domain Restricted Sharing) org policy by default — toggle a project-level
# override during apply, then restore it. Existing bindings persist on restore.
resource "google_pubsub_topic_iam_member" "chat_push_publisher" {
  topic  = google_pubsub_topic.ingress.id
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:chat-api-push@system.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# Per-partner topics + subscriptions (one set per entry in var.partner_map).
# ---------------------------------------------------------------------------

resource "google_pubsub_topic" "partner" {
  for_each = var.partner_map
  name     = "hermes-chat-${each.value}"
}

# Pull subscription per partner. A shared subscription would round-robin events
# across containers (cross-partner leak). Each container subscribes only to its
# OWN per-partner subscription.
resource "google_pubsub_subscription" "partner" {
  for_each = var.partner_map
  name     = "hermes-chat-${each.value}-sub"
  topic    = google_pubsub_topic.partner[each.key].id

  # 7-day retention so a backlog survives a gateway restart / snapshot restore.
  message_retention_duration = "604800s"
  retain_acked_messages      = false

  expiration_policy {
    ttl = "" # never expire (default would delete an idle subscription)
  }
}

# Instance SA can pull from each partner's subscription. (Layer-2 boundary
# still wide open — see header comment.)
resource "google_pubsub_subscription_iam_member" "sa_subscriber" {
  for_each     = var.partner_map
  subscription = google_pubsub_subscription.partner[each.key].id
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${var.subscriber_sa_email}"
}

resource "google_pubsub_subscription_iam_member" "sa_viewer" {
  for_each     = var.partner_map
  subscription = google_pubsub_subscription.partner[each.key].id
  role         = "roles/pubsub.viewer"
  member       = "serviceAccount:${var.subscriber_sa_email}"
}

# ---------------------------------------------------------------------------
# Router Cloud Function (2nd gen, Python, Eventarc-triggered off ingress).
# ---------------------------------------------------------------------------

# Dedicated runtime SA — least privilege: Subscriber on ingress (granted via
# the Eventarc trigger), Publisher on each per-partner topic.
resource "google_service_account" "router" {
  account_id   = "hermes-chat-router"
  display_name = "Hermes Chat router (Cloud Function runtime SA)"
}

resource "google_pubsub_topic_iam_member" "router_publisher" {
  for_each = var.partner_map
  topic    = google_pubsub_topic.partner[each.key].id
  role     = "roles/pubsub.publisher"
  member   = "serviceAccount:${google_service_account.router.email}"
}

# Eventarc plumbing — these bindings are commonly required for 2nd-gen
# functions with Pub/Sub triggers; without them deployment or invocation fails.
resource "google_project_iam_member" "router_event_receiver" {
  project = var.project
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.router.email}"
}

resource "google_project_iam_member" "router_run_invoker" {
  project = var.project
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.router.email}"
}

# Pub/Sub's service agent mints tokens for the CF runtime SA to deliver
# events via push (Eventarc uses Pub/Sub push under the hood for CF 2nd gen).
# Without this binding, Eventarc trigger creation fails with a vague
# "permission denied".
resource "google_service_account_iam_member" "pubsub_sa_token_creator" {
  service_account_id = google_service_account.router.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# Source upload: zip router/ on apply, push to a dedicated bucket.
resource "google_storage_bucket" "cf_source" {
  name                        = "${var.project}-cf-source"
  location                    = "us-central1"
  uniform_bucket_level_access = true
}

data "archive_file" "router" {
  type        = "zip"
  source_dir  = "${path.module}/router"
  output_path = "${path.module}/.terraform/tmp/router.zip"
}

# Hash in the object name so a source change invalidates the cache and the
# function picks up the new build.
resource "google_storage_bucket_object" "router_zip" {
  name   = "router-${data.archive_file.router.output_md5}.zip"
  bucket = google_storage_bucket.cf_source.name
  source = data.archive_file.router.output_path
}

resource "google_cloudfunctions2_function" "router" {
  name     = "hermes-chat-router"
  location = "us-central1"

  build_config {
    runtime     = "python311"
    entry_point = "route"
    source {
      storage_source {
        bucket = google_storage_bucket.cf_source.name
        object = google_storage_bucket_object.router_zip.name
      }
    }
  }

  service_config {
    max_instance_count    = 5
    available_memory      = "256M"
    timeout_seconds       = 60
    service_account_email = google_service_account.router.email

    # The router's only mutable knob — partner map as JSON. Changing partners
    # in the tfvars and re-applying updates this env var; CF picks up the new
    # config on the next cold start (or instantly on warm-start refresh).
    environment_variables = {
      PARTNER_MAP = jsonencode(var.partner_map)
    }
  }

  event_trigger {
    trigger_region        = "us-central1"
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.ingress.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.router.email
  }

  # Ensure IAM lands before the trigger tries to use it.
  depends_on = [
    google_project_iam_member.router_event_receiver,
    google_project_iam_member.router_run_invoker,
    google_service_account_iam_member.pubsub_sa_token_creator,
  ]
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "ingress_topic" {
  description = "Set this as the Chat app's Pub/Sub topic in the Cloud Console (Configuration → Connection settings → Cloud Pub/Sub)."
  value       = "projects/${var.project}/topics/${google_pubsub_topic.ingress.name}"
}

output "partner_subscriptions" {
  description = "Map of partner email → fully-qualified subscription path. Use to populate GOOGLE_CHAT_SUBSCRIPTION_NAME in each container."
  value = {
    for email, partner in var.partner_map :
    email => "projects/${var.project}/subscriptions/${google_pubsub_subscription.partner[email].name}"
  }
}

output "router_function_name" {
  value = google_cloudfunctions2_function.router.name
}
