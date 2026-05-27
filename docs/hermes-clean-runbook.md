# Hermes Agents on GCP — Clean Build Runbook (v2)

Build a **trusted, identity-free golden container** (`hermes-clean`), prove the full
inference + tool-calling spine, snapshot it, then clone + personalize one agent per
partner. This supersedes the v1 runbook — the model backend is now **Gemini on Vertex
AI via a LiteLLM proxy using the GCE instance service account**, not OpenRouter/AI Studio.

> **Why this rewrite exists.** The v1 plan assumed OpenRouter or an AI Studio API key.
> In practice the org-managed Google account hit wall after wall on the consumer
> (AI Studio) path — billing prepay, `API_KEY_SERVICE_BLOCKED`, "project denied access."
> The Vertex AI path authenticates cleanly with the instance SA (no key file), draws on
> GCP billing, and has enterprise data terms. LiteLLM bridges Hermes (OpenAI-wire) to
> Vertex. This is the proven path.

---

## 0. Foothold — the facts you proved, in one place

Keep this block. It's the orientation for any future session.

| Fact | Value |
| --- | --- |
| GCP project | `your-gcp-project-id` |
| Auth | GCE **instance SA via ADC** — no key file, works *inside* the container |
| Model (primary) | `gemini-3.5-flash` → **`vertex_location: global`** |
| Model (fallback) | `gemini-2.5-flash` → **`vertex_location: us-central1`** |
| LiteLLM deps | `litellm[proxy]` **plus** `google-cloud-aiplatform` (the second is easy to forget) |
| LiteLLM endpoint | `http://127.0.0.1:4000` (OpenAI-compatible) |
| Hermes main model | `provider: custom`, `base_url: http://127.0.0.1:4000`, `default: gemini-3.5-flash` |
| Proven test | "what's the weather in Brockton MA?" → model calls terminal `curl wttr.in` → answers |

**Model-name landmines (each layer wants a different form):**
- Inside LiteLLM `litellm_params.model`: `vertex_ai/gemini-3.5-flash` (the `vertex_ai/` prefix routes to Vertex).
- What Hermes / curl send: plain `gemini-3.5-flash` (LiteLLM matches it against `model_name`).
- Keep "gemini" in the public `model_name` — Hermes's `tool_use_enforcement: auto` keys
  off the model string and applies Gemini tool-use guidance only when it sees "gemini".

---

## 1. Isolation & golden-image philosophy

Three layers. The golden image is **layer 1 only** — never layers 2–3.

| Layer | Contents | Same for all partners? | In golden image? |
| --- | --- | --- | --- |
| **1 — Infrastructure** | OS packages, Hermes, LiteLLM, Vertex wiring, model config, systemd services | Yes | **YES** |
| **2 — Identity** | Google Workspace OAuth token, Google Chat SA + Pub/Sub, WhatsApp pairing, allowed-users | No (per partner) | **NO** |
| **3 — Live state** | `~/.hermes/memories/`, `sessions/`, conversation history | No | **NO** |

**Why rebuild clean instead of reusing `dan-agent`:** that container had chat-setup
experiments poked into it, so its layer-1 purity is uncertain. A golden image you don't
trust is worse than none — you'd clone the cruft into every partner. Building fresh from
this recipe gives *certainty* it's layer-1-only. `dan-agent` retires to experiment duty.

**Naming:** the golden base gets a **neutral** name (`hermes-clean`). Identifying names
(`hermes-dan`, `hermes-<partnerB>`) belong on the **clones**, not the base — otherwise a
clone of `dan-agent` ends up running someone else's agent. Name at clone time, not bake time.

**Shared-kernel note (accepted):** containers share the host kernel, so the blast radius
of an escape is all three partners' Google credentials. Accepted for three trusting
co-founders. Guardrails: unprivileged containers (Incus default), no shared bind-mounts,
token files `chmod 600`.

---

## 2. Prerequisites (already done, verify)

- FreeDB host up; Incus initialized via its preseed (`platform/config/incus.yaml`),
  which created the `default` profile, `pd-standard` ZFS pool, and `incusbr0` bridge.
- You drive Incus with **`sudo incus ...`** (the `dbiagini` user isn't in the incus admin
  group — consistent with how FreeDB operates). Don't run `incus admin init` again.
- Instance SA has `roles/aiplatform.user`; VM scopes include `cloud-platform`; the Vertex
  API is enabled. (Proven by the raw curl returning a completion.)

Optional `hermes` profile (CPU uncapped, memory as a containment fuse — see discussion):
```bash
sudo incus profile create hermes
sudo incus profile set hermes limits.memory 3GiB        # fuse, not a quota; raise live anytime
sudo incus profile set hermes security.privileged false
sudo incus profile set hermes security.nesting false
# no limits.cpu — let agents burst
```

---

## 3. Build the golden container (layer 1) — the clean recipe

Every step here is layer-1 and was proven tonight. Do NOT touch messaging/OAuth here.

### 3.1 Launch
```bash
sudo incus launch images:ubuntu/24.04 hermes-clean --profile default --profile hermes
sudo incus exec hermes-clean -- bash      # drop into the container
```

### 3.2 System packages (minimal Ubuntu image is missing several)
```bash
apt-get update
apt-get install -y xz-utils ca-certificates build-essential ripgrep ffmpeg git python3-dev, libffi-dev
```
- `git` - prereq for hermes install
- `xz-utils` — without it the Hermes installer's Node download fails (`xz: Cannot exec`).
- `ripgrep` / `ffmpeg` — Hermes optional tools (file search; voice transcode). Installing
  here means the Hermes installer never needs sudo for them → the agent user stays sudo-less.
- `build-essential` / `ca-certificates` — native wheels + TLS, head off later failures.

### 3.3 Create the agent user (non-root, sudo-less)
```bash
adduser --disabled-password --gecos "" hermes
su - hermes        # do all Hermes/LiteLLM work as this user
```

### 3.4 Install Hermes
```bash
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash
source ~/.bashrc
hermes doctor
```

### 3.5 Install LiteLLM persistently (NOT ephemeral uvx)
The tonight-proof used `uvx` (throwaway). For a snapshot it must be a real install with
**both** deps. Using `uv` (already present):
```bash
uv tool install 'litellm[proxy]' --with google-cloud-aiplatform
# verify:
litellm --version
```
> The `google-cloud-aiplatform` dep is what makes ADC work — without it you get
> `ModuleNotFoundError: No module named 'google'` when LiteLLM tries to mint the SA token.

### 3.6 LiteLLM config — the proven model/location matrix
```bash
mkdir -p ~/litellm
cat > ~/litellm/config.yaml << 'EOF'
model_list:
  - model_name: gemini-3.5-flash
    litellm_params:
      model: vertex_ai/gemini-3.5-flash
      vertex_project: your-gcp-project-id
      vertex_location: global
  - model_name: gemini-2.5-flash
    litellm_params:
      model: vertex_ai/gemini-2.5-flash
      vertex_project: your-gcp-project-id
      vertex_location: us-central1
EOF
```
No `vertex_credentials:` line → LiteLLM falls back to ADC = the instance SA.

### 3.7 Verify the metadata server is reachable from inside the container
This is the one thing that differs host-vs-container. Proven working in `dan-agent`, but
re-confirm in the clean build before trusting it:
```bash
curl -s -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/email"
# should print the instance SA email. If it hangs/fails, ADC won't work in-container and
# you'd need to mount a SA key JSON + set vertex_credentials: in 3.6 (fallback only).
```

### 3.8 Point Hermes at LiteLLM
```bash
hermes config set model.provider custom
hermes config set model.base_url http://127.0.0.1:4000
hermes config set model.default gemini-3.5-flash
# Hermes sends *some* key on custom endpoints; LiteLLM (no master_key) ignores it:
echo 'OPENAI_API_KEY=sk-localdummy' >> ~/.hermes/.env
```
Confirm there's no stale `model.provider: gemini` / `GEMINI_BASE_URL` / `GOOGLE_API_KEY`
left from earlier experiments (`grep -i 'base_url\|gemini\|google' ~/.hermes/.env`).

### 3.9 Prove the spine (the gate that defines "golden-ready")
Start LiteLLM (foreground for the test):
```bash
litellm --config ~/litellm/config.yaml &
# wait for "Uvicorn running on http://0.0.0.0:4000"
```
Then:
```bash
hermes chat
# type: what's the weather in brockton MA?
```
**Pass = the model issues a tool call (terminal/curl), then answers with the weather, and
the status bar shows `gemini-3.5-flash`.** That proves Hermes→LiteLLM→Vertex→SA→Gemini +
tool-calling on 3.5. Dependency-free alternative: "run the command `date` and tell me the result."

If 3.5 misbehaves on tool calls, switch to the proven fallback:
`hermes config set model.default gemini-2.5-flash`.

### 3.10 Make both services persistent (so the snapshot captures them)
LiteLLM — create a systemd unit (run as root in the container):
```bash
exit   # back to root from the hermes user
cat > /etc/systemd/system/litellm.service << 'EOF'
[Unit]
Description=LiteLLM proxy (Vertex via instance SA)
After=network-online.target
Wants=network-online.target

[Service]
User=hermes
ExecStart=/home/hermes/.local/bin/litellm --config /home/hermes/litellm/config.yaml
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now litellm
systemctl status litellm        # confirm active
```
> Verify the `ExecStart` path — `uv tool install` may place the binary at
> `~/.local/bin/litellm` or under a uv tools dir; adjust to match `which litellm` as hermes.

Hermes gateway — **DECISION POINT, see §4.** The gateway is what *listens* for partner
messages. It can go in golden (started but with no platform enabled yet) OR be part of
per-partner setup. Recommendation below.

### 3.11 Bake the Google Chat dependencies (`golden-v3` and later)
Google Chat is the default messaging platform for the partner agents. The
Hermes Chat plugin needs four pieces baked into golden so per-partner clones
go from idle → live with one `add-partner.sh` call:

```bash
# A. Systemd drop-ins — make .env load and stdout unbuffered under systemd.
sudo incus exec hermes-clean -- bash -c '
  mkdir -p /etc/systemd/system/hermes-gateway.service.d
  cat > /etc/systemd/system/hermes-gateway.service.d/env.conf <<EOF
[Service]
EnvironmentFile=/home/hermes/.hermes/.env
EOF
  cat > /etc/systemd/system/hermes-gateway.service.d/python-unbuffered.conf <<EOF
[Service]
Environment="PYTHONUNBUFFERED=1"
EOF
  systemctl daemon-reload
'

# B. Python deps for the Chat plugin (no Hermes extra exists in v0.14.0).
sudo incus exec hermes-clean --user $(sudo incus exec hermes-clean -- id -u hermes) \
  --env HOME=/home/hermes \
  --env VIRTUAL_ENV=/home/hermes/.hermes/hermes-agent/venv -- \
  /home/hermes/.local/bin/uv pip install \
    google-cloud-pubsub google-api-python-client google-auth google-auth-oauthlib
```

> Golden ships with `platforms.google_chat.enabled` UNSET so the idle gateway
> boots quietly. `add-partner.sh` runs `hermes config set platforms.google_chat.enabled true`
> per clone — partner activation is layer 2.

### 3.12 Clean live state, then snapshot
Strip any test conversation/session so the golden image is truly state-free:
```bash
# as hermes:
rm -rf ~/.hermes/sessions/* ~/.hermes/logs/* 2>/dev/null
# (leave config.yaml, .env, SOUL.md — those are layer-1)
```
Snapshot:
```bash
# on the host:
sudo incus snapshot create hermes-clean golden-v3
sudo incus snapshot list hermes-clean
```
**This snapshot is your golden base and your disaster-recovery point.**
Bump the snapshot label (`golden-v3`, `-v4`, ...) whenever §3.11 changes so
clones always pick up the current bake recipe.

---

## 4. Decision: does the Hermes gateway belong in golden?

The gateway service itself (the listener process) is layer-1 — identical for everyone.
What's *per-partner* is **which platform is enabled and its credentials** (layer 2).

**Recommended:** install the gateway as a system service in golden but **enable no
platform**, so golden boots a running-but-idle gateway. Each clone then only adds that
partner's platform config and restarts the gateway. This keeps the heavy lifting in golden.

```bash
# in golden, as appropriate user per Hermes docs:
sudo hermes gateway install --system
# do NOT configure Google Chat / WhatsApp here — that's layer 2
```
Trade-off: a golden gateway with no platform does nothing until personalized — which is
exactly right. If you'd rather keep golden minimal, skip this and install the gateway
during per-partner setup instead. Either is defensible; the recommended path saves repetition.

---

## 5. Clone + personalize per partner (layer 2)

For each partner (do partner "dan" first as the template):

### 5.1 Clone the golden snapshot into a named container
```bash
sudo incus copy hermes-clean/golden-v3 hermes-dan
sudo incus start hermes-dan
```
The clone inherits all of layer 1 — working LiteLLM, Hermes, model config, Chat
plugin deps, systemd drop-ins — with zero re-setup. Name it for the partner
(`hermes-dan`, `hermes-<partnerB>`, `hermes-<partnerC>`).

### 5.2 Google Workspace skill — per-partner OAuth
- One-time host-side: one Desktop-app OAuth client in `your-gcp-project-id`, reused across
  all partners (it identifies the *app*, not the user). Enable Gmail/Calendar/Drive/Docs/
  Sheets APIs. As Workspace admin, confirm app-access policy won't block it.
- Per partner, in their container: place `client_secret.json`, then run the skill's setup
  (`scripts/setup.py --auth-url --services calendar,drive,...` → partner approves on their
  own device → paste the redirected URL back → `--auth-code ...`). Token lands at
  `~/.hermes/google_token.json` (`chmod 600`). Scope-minimize per partner.

### 5.3 Google Chat (all partners) — muxed architecture
**One** Chat app feeds **all** partners via a single ingress topic, a Cloud Function
router that demuxes by sender email, and per-partner topics + subscriptions. See the
header comment in `agents/main.tf` for the full design and trade-offs. Why muxed: Google
caps Chat apps at one per GCP project, so per-partner apps don't scale; the router gets
us logical isolation without that limit.

Cloud side is fully managed by `agents/main.tf`:
- `hermes-chat-ingress` topic + `chat-api-push@system.gserviceaccount.com` = Publisher
- Router Cloud Function (2nd gen, Python) with Eventarc trigger on the ingress topic
- Per-partner topics (`hermes-chat-<partner>`) and pull subscriptions (`hermes-chat-<partner>-sub`)
- IAM: instance SA = Subscriber + Viewer on each per-partner sub
- Router SA: Publisher on each per-partner topic, plus `run.invoker` at BOTH project
  and service level (project-level alone is silently insufficient for CF 2nd gen)

Add a partner = add an entry to `partner_map` in `agents/backoffice.tfvars` and
`tofu apply -var-file=backoffice.tfvars`. Partner data is in the gitignored tfvars
only; the tf code is fully parameterized.

Hermes authenticates to Pub/Sub via ADC — `plugins/platforms/google_chat/adapter.py`
falls back to `google.auth.default()` when `GOOGLE_CHAT_SERVICE_ACCOUNT_JSON` is unset,
which picks up the instance SA. No per-partner SA, no key file on disk; the org policy
`iam.disableServiceAccountKeyCreation` stays enforced. The router gives logical routing,
not IAM isolation — accepted for three trusting co-founders. Migrate to per-partner SAs
via impersonation before opening this up further.

Per-partner container wiring is one script:
```bash
cd ~/backoffice/agents
./add-partner.sh <partner> <partner@realia.com.br> hermes-<partner>
```
This writes the `GOOGLE_CHAT_*` env vars into `~/.hermes/.env` in the container,
enables `platforms.google_chat.enabled: true` in `~/.hermes/config.yaml`, and
restarts `hermes-gateway`. Idempotent — safe to re-run after a tofu apply that
rotates partners.

**One-time Chat app config** in the Console
(https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=…):
- App status: **LIVE — available to users**
- Connection: **Cloud Pub/Sub** → `projects/<project>/topics/hermes-chat-ingress`
- Interactive features: ON
- Functionality: "Join spaces and group conversations" checked
- Visibility: allowlist the partner emails (`dan@…, hassan@…, luiz@…`)

**DRS gotcha** (`[[drs-blocks-chat-push-binding]]`): the topic publisher binding for
`chat-api-push@system.gserviceaccount.com` is blocked by the
`iam.allowedPolicyMemberDomains` (Domain Restricted Sharing) org policy by default.
Toggle a project-level override during apply, then restore (existing bindings persist
on restore).

### 5.4 WhatsApp (partner "dan" only)
Dedicated number (Google Voice / prepaid SIM / VoIP — not personal). `hermes whatsapp` →
QR pair. `.env`: `WHATSAPP_ENABLED=true`, `WHATSAPP_MODE=bot`, `WHATSAPP_ALLOWED_USERS=<num>`.
`config.yaml`: `whatsapp.unauthorized_dm_behavior: ignore`. Session at
`~/.hermes/platforms/whatsapp/session` is persistent on the ZFS dataset (chmod 700).
Expect occasional re-pairs after WhatsApp protocol updates.

### 5.5 Restart gateway, snapshot the configured agent
```bash
# in the container, restart so it picks up the platform config
sudo systemctl restart hermes-gateway     # or `hermes gateway restart` per docs
```
```bash
# on host — per-partner restore point (this one HAS their identity, keep it separate)
sudo incus snapshot create hermes-dan configured
```

---

## 6. Disaster recovery

- **Screwed up a partner's container:** `sudo incus snapshot restore hermes-dan configured`
  (back to their working configured state), or restore from `golden` clone + redo §5 for a
  truly fresh start.
- **Need a new partner:** `sudo incus copy hermes-clean/golden hermes-<new>` → §5.
- **Golden itself needs an update (new Hermes/LiteLLM version):** start `hermes-clean`,
  apply updates, re-run the §3.9 spine test, re-snapshot `golden`. Existing partner
  containers are unaffected until you choose to rebuild them from the new golden.

---

## 7. Open items / decisions still yours

1. **Gateway-in-golden vs per-partner** (§4) — recommended: idle gateway in golden.
2. **Google Chat vs WhatsApp per partner** — Chat for all (cleaner, admin-controlled),
   WhatsApp added only for "dan".
3. **Memory limit value** — `3GiB` fuse is a starting guess; tune to real usage. Raise live
   with `sudo incus config set hermes-<name> limits.memory <N>GiB`.
4. **Retire `dan-agent`** — keep as experiment sandbox or delete once `hermes-clean` is golden.
5. **LiteLLM binary path in the systemd unit** (§3.10) — verify against `which litellm`.

---

## 8. Partner usage — finding and using your Hermes bot

Once the partner's container is provisioned and `add-partner.sh` has been run,
their bot is reachable from Google Chat. Send these instructions to each partner.

### 8.1 Find the bot

In Google Chat as your Workspace account (e.g. `dan@realia.com.br`):

1. Open Chat — https://mail.google.com/chat or via the Gmail sidebar.
2. Click **+ New chat** (the plus button next to "Direct messages" in the left rail).
3. Type **`Hermes`** in the search box.
4. Click the Hermes result — Chat opens a DM with the bot.

If the bot doesn't appear, your email isn't in the Chat app's Visibility allowlist
(see §5.3 — "Visibility: allowlist the partner emails"). The Workspace admin needs
to add it. Note: changes can take up to 24 hours to propagate, but usually land within
a few minutes.

### 8.2 First message — the `/sethome` prompt

The first time you message Hermes, you'll see a prompt before the real reply:

> 📬 No home channel is set for Google_Chat. A home channel is where Hermes delivers
> cron job results and cross-platform messages.
>
> Type `/sethome` to make this chat your home channel, or ignore to skip.

This is **normal and expected** — Hermes asks every new platform once. Your two options:

- **Type `/sethome`** (recommended for partners): pins this DM as where Hermes pushes
  cron job output, scheduled reminders, and cross-platform notifications. Set once
  and forget — survives container restarts. Almost certainly what you want for a
  personal DM with your bot.
- **Ignore it**: Hermes will keep responding to direct questions, but anything
  scheduled (cron jobs, reminders, async deliveries) won't have a destination. You'll
  see the prompt again on future fresh contexts.

The bot replies to your original question right after the prompt either way.

### 8.3 Day-to-day use

- **Ask anything** — Hermes routes to Gemini 3.5 Flash via the Vertex backend and
  has tool access (web search, terminal commands, file ops, scheduling).
- **Schedule a check-in**: `remind me every weekday at 9am to review the kanban`.
  Cron-style natural language; results are delivered to your home channel.
- **Run a tool**: `what's the weather in São Paulo?` triggers a web lookup;
  `summarize this URL: https://...` fetches and summarizes.
- **Quirky behaviors to know about**:
  - The bot's first reply after a long idle period may take a few seconds while
    a Cloud Function scales up — subsequent messages are fast.
  - Avatar / display name are app-level (one app, all partners) — that's intentional
    given the muxed architecture. Your DM is still scoped to your account.

### 8.4 If the bot stops responding

Most common causes, in order of likelihood:

1. **VM stopped** — check `gcloud compute instances list --project=<project>`.
2. **Gateway service crashed** in your container — on the host,
   `sudo incus exec hermes-<partner> -- systemctl status hermes-gateway --no-pager`.
3. **Tofu drift** — someone applied/destroyed in `agents/` and the router CF is
   redeploying. Check `gcloud functions logs read hermes-chat-router --gen2 --region=us-central1 --limit=10`.
4. **Chat app config drift** — someone toggled "App status" off in the Console.

Escalate to the maintainer with the output of whichever command surfaced something
unusual. Full diagnostic path is in `agents/main.tf` comments and the project memory.
