# backoffice — Hermes agents on GCP

Infrastructure-as-code and provisioning scripts for running personal
[Hermes](https://github.com/NousResearch/hermes-agent) agents on GCP, one
per co-founder. A single GCE host runs FreeDB + Incus; each agent lives in
its own LXC container with its own messaging credentials.

This repo holds **only** the cloud plumbing and host-side config. The full
build narrative — including the host setup, the golden-container recipe,
and per-partner identity wiring — lives in [`docs/hermes-clean-runbook.md`](docs/hermes-clean-runbook.md).
Read that first if you're new to the project.

## Architecture in one paragraph

A GCE VM (`infra/`) hosts FreeDB and Incus. Inside Incus, one
**golden container** (`hermes-clean`) is built once with Hermes + LiteLLM
proxying to Vertex AI via the instance service account — no API keys. That
container is snapshotted, then cloned per partner (`hermes-dan`, etc.) and
personalised with that partner's Google Workspace OAuth and a dedicated
Google Chat Pub/Sub channel provisioned by `agents/`.

## Layout

```
infra/        Terraform for the GCE FreeDB host (VPC, firewall, VM, backup bucket)
agents/       Terraform + wrapper script for per-partner Google Chat Pub/Sub
config/       Host/container service config (LiteLLM, systemd units)
docs/         The end-to-end build runbook
```

## Prerequisites

- `gcloud` authed as a project owner
- `tofu` (or `terraform`) ≥ 1.6
- A GCP project with billing enabled
- A GCS bucket for Terraform state (see Bootstrap below)
- The Vertex AI, Compute Engine, Pub/Sub, and Google Chat APIs enabled

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

Outputs include the FreeDB instance name and its static external IP.

### 4. Build the golden container

SSH into the GCE host and follow [`docs/hermes-clean-runbook.md`](docs/hermes-clean-runbook.md)
§3 to build `hermes-clean`. The runtime LiteLLM config template is in
`config/litellm/config.yaml.example` — copy it into the container at
`/home/hermes/litellm/config.yaml` and replace `your-gcp-project-id` with
your real project ID. The systemd unit in `config/etc/systemd/system/litellm.service`
drops straight into `/etc/systemd/system/`.

### 5. Onboard a partner

For each co-founder, clone the golden snapshot (`incus copy hermes-clean/golden hermes-<name>`)
and then provision their Chat channel from your laptop:

```bash
cd agents/
tofu init -backend-config=backend.hcl
export PROJECT=YOUR_GCP_PROJECT_ID
./provision-chat.sh <partner> <allowed-email> <container-name>
# e.g.  ./provision-chat.sh dan dan@example.com hermes-dan
```

The script runs the per-partner Terraform (own SA, own topic, own
subscription, two IAM bindings), generates the SA key with `gcloud`
(deliberately outside TF state), pushes it into the container, writes
`~/.hermes/.env`, and restarts the gateway. It prints the one manual
Cloud Console step at the end (the Chat app connection).

Each partner gets their own `tofu workspace` so per-partner state is
isolated — `provision-chat.sh` handles the workspace switch.

## What's intentionally not in this repo

- **Service account keys**, OAuth tokens, `.env` files — generated at
  provisioning time, live on the host/in the containers, never committed.
- **Terraform state** — in the GCS bucket configured by `backend.hcl`.
- **Chat app config** (name, avatar, Pub/Sub connection) — Console-only,
  no API exists. `provision-chat.sh` prints the steps to run once per
  partner.

## Security model

Three trusting co-founders sharing one host kernel. Guardrails:

- Unprivileged Incus containers (`security.privileged=false`, no nesting).
- One service account, topic, and pull subscription per partner — a
  leaked credential reaches only that partner's chat stream.
- No project-level IAM on partner SAs; their only authority is
  Subscriber+Viewer on their own subscription.
- LiteLLM → Vertex authenticates via the GCE instance SA (ADC) — no key
  file on disk for the model backend.
- Token / key files inside containers are `chmod 600`, owned by `hermes`.

The accepted residual risk is a container-escape exposing all three
partners' Google credentials. If you grow past three trusting users,
move to one VM per partner.
