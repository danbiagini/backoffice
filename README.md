# backoffice — Hermes agents on GCP

Infrastructure-as-code and provisioning scripts for running personal
[Hermes](https://github.com/NousResearch/hermes-agent) agents on GCP, one
per co-founder. A single GCE host runs Incus; each agent lives in its own
LXC container with its own messaging credentials.

This repo holds **only** the cloud plumbing and host-side config. The full
build narrative — including the host setup, the golden-container recipe,
per-partner identity wiring, and partner usage — lives in
[`docs/hermes-clean-runbook.md`](docs/hermes-clean-runbook.md). Read that
first if you're new to the project.

## Architecture in one paragraph

A GCE VM (`infra/`) hosts Incus. Inside Incus, one **golden container**
(`hermes-clean`) is built once with Hermes + LiteLLM proxying to Vertex AI
via the instance service account — no API keys. The container is snapshotted
(`golden-v3`), then cloned per partner (`hermes-dan`, etc.) and personalised
with that partner's Google Chat config. Chat events for all partners flow
through a **single shared Chat app** into a Pub/Sub ingress topic; a Cloud
Function router (`agents/`) demuxes by sender email and republishes to each
partner's own per-partner topic + subscription. This sidesteps Google's
one-Chat-app-per-project limit while preserving per-partner subscription
isolation.

## Layout

```
infra/        Terraform for the GCE host (VPC, firewall, VM, backup bucket)
agents/       Terraform for the muxed Chat plumbing + add-partner.sh
              (ingress topic, CF router, per-partner topics, IAM)
config/       Host/container service config (LiteLLM, systemd units)
docs/         End-to-end build runbook + partner usage guide
```

## Prerequisites

- `gcloud` authed as a project owner
- `tofu` (or `terraform`) ≥ 1.6
- A GCP project with billing enabled
- A GCS bucket for Terraform state (see Bootstrap below)
- The Vertex AI, Compute Engine, Pub/Sub, Cloud Functions, Eventarc, and
  Google Chat APIs enabled

## First-time setup

### 1. Bootstrap the Terraform state bucket

Create the GCS bucket Terraform will use for state (this is the one piece
that can't itself be managed by Terraform-with-remote-state):

```bash
gcloud storage buckets create gs://YOUR_TFSTATE_BUCKET \
  --project=YOUR_GCP_PROJECT_ID \
  --location=us-central1 \
  --uniform-bucket-level-access
gcloud storage buckets update gs://YOUR_TFSTATE_BUCKET --versioning
```

### 2. Configure your local backend pointers

Both `infra/` and `agents/` use [partial backend config](https://developer.hashicorp.com/terraform/language/settings/backends/configuration#partial-configuration) —
the bucket name lives in a local `backend.hcl` that is gitignored. Copy
the templates and fill in your bucket:

```bash
cp infra/backend.hcl.example   infra/backend.hcl
cp agents/backend.hcl.example  agents/backend.hcl
# edit both to set bucket = "YOUR_TFSTATE_BUCKET"
```

Then copy the infra tfvars template and edit it to match your project:

```bash
cp infra/backoffice.tfvars.example infra/backoffice.tfvars
# edit project, service_account_id, and (optionally) env / subnet_cidr
```

### 3. Provision the host

```bash
cd infra/
tofu init -backend-config=backend.hcl
tofu apply -var-file=backoffice.tfvars
```

Outputs include the host instance name and its static external IP.

### 4. Build the golden container

SSH into the GCE host and follow [`docs/hermes-clean-runbook.md`](docs/hermes-clean-runbook.md)
§3 to build `hermes-clean` and snapshot it as `golden-v3`. The runtime
LiteLLM config template is in `config/litellm/config.yaml.example` — copy
it into the container at `/home/hermes/litellm/config.yaml` and replace
`your-gcp-project-id` with your real project ID. The systemd unit in
`config/etc/systemd/system/litellm.service` drops straight into
`/etc/systemd/system/`.

### 5. Stand up the muxed Chat plumbing

On the host, in `agents/`, copy and fill in the tfvars (partner emails →
partner IDs go in `partner_map`), then apply:

```bash
cd agents/
cp backoffice.tfvars.example backoffice.tfvars
# edit project, subscriber_sa_email, and add your partner_map entries

tofu init -backend-config=backend.hcl
tofu apply -var-file=backoffice.tfvars
```

This creates the ingress topic, the Cloud Function router, per-partner
topics + subscriptions, and all the required IAM. A one-time Chat app
configuration in the Cloud Console points the app at the ingress topic
— see runbook §5.3 for the checklist.

### 6. Onboard a partner

For each co-founder, clone the golden snapshot and run `add-partner.sh`:

```bash
sudo incus copy hermes-clean/golden-v3 hermes-<partner>
sudo incus start hermes-<partner>

cd agents/
./add-partner.sh <partner> <partner@your-domain> hermes-<partner>
# e.g.  ./add-partner.sh dan dan@example.com hermes-dan
```

The script must run on the GCE host — it queries the instance metadata
server for the project ID and instance SA, then uses `sudo incus` to wire
the container: writes `~/.hermes/.env`, enables the `google_chat` platform
in `~/.hermes/config.yaml`, and restarts the Hermes gateway. Idempotent —
safe to re-run.

Hermes authenticates to Pub/Sub via Application Default Credentials —
no per-partner service account, no JSON key on disk. The GCE instance SA
is the subscriber on every partner's subscription, which keeps
`iam.disableServiceAccountKeyCreation` enforceable. See the runbook §5.3
for the security tradeoff (shared identity in audit logs, blast radius
unchanged from the documented shared-kernel posture).

## What's intentionally not in this repo

- **Service account keys**, OAuth tokens, `.env` files — generated at
  provisioning time, live on the host/in the containers, never committed.
- **Terraform state** — in the GCS bucket configured by `backend.hcl`.
- **Chat app config** (name, avatar, Pub/Sub connection, visibility) —
  Console-only, no API exists. Runbook §5.3 lists the one-time clicks.
- **Partner identities** — `agents/backoffice.tfvars` is gitignored;
  partner emails and short IDs live on the host only.

## Security model

Three trusting co-founders sharing one host kernel. Guardrails:

- Unprivileged Incus containers (`security.privileged=false`, no nesting).
- One ingress topic and one CF router shared across partners; per-partner
  topics and pull subscriptions for delivery isolation. A leaked container
  reaches only that partner's chat stream at the delivery layer.
- No project-level IAM on partner-specific resources beyond what the
  router CF runtime SA requires; the GCE instance SA's authority on each
  partner subscription is Subscriber+Viewer only.
- LiteLLM → Vertex authenticates via the GCE instance SA (ADC) — no key
  file on disk for the model backend.
- Token / key files inside containers are `chmod 600`, owned by `hermes`.

The accepted residual risk is a container-escape exposing all three
partners' Google credentials, plus the muxed-router design where the
instance SA is a logical (not IAM-enforced) subscriber on every partner
sub. If you grow past three trusting users, see the runbook §7
"Outstanding" — move to per-partner SAs via impersonation, and consider
one VM per partner.
