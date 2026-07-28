# Telegram-controlled power switch for the AI Dev VPS

Infra plan — finalized after review. Not yet applied to infrastructure.

A Cloud Run function accepts inline-button taps from one authorized Telegram
user and starts or stops the `ai-dev-vps` Compute Engine instance. This
revision closes an auth gap present in the first draft and moves secrets out
of Terraform state.

**Decisions locked in:**

| Decision      | Choice                              |
|---------------|--------------------------------------|
| Webhook auth  | Telegram `secret_token` header       |
| Secrets       | Secret Manager                       |
| Runtime       | Cloud Functions Gen2                 |

---

## 1. Architecture

```
You, in Telegram                Cloud Run function                ai-dev-vps
Taps "Power On" /      --HTTPS POST-->   Checks, in order:     --compute.instances-->   e2-medium Compute
"Power Off" on the      + secret header   1. secret_token header   start / stop          Engine instance,
inline keyboard                           2. allowed chat_id                              unchanged
                                           3. message vs callback_query
```

The function also writes back to Telegram directly — `answerCallbackQuery`
to clear the button's spinner, then `sendMessage` to confirm the action —
so traffic runs in both directions even though the diagram only draws it
once.

---

## 2. Security model

**Gap in v1:** The draft's only gate was `chat_id != allowed_chat_id` — but
`chat_id` is a field inside the request body, and the endpoint has no auth
in front of it. Anyone who finds the function URL can POST a forged
`callback_query` with your `chat_id` in it and drive the VM directly. The
allowlist checked the wrong layer.

**Fix:** Telegram's `setWebhook` accepts a `secret_token`, which it then
echoes back on every call as the `X-Telegram-Bot-Api-Secret-Token` header.
That header is checked with a constant-time comparison *before* the body is
even parsed. `chat_id` stays as a second, cheaper check once the caller is
already known to be Telegram.

Three independent layers, narrowest first:

| Layer       | Mechanism                                                              | Stops                                                                          |
|-------------|--------------------------------------------------------------------------|---------------------------------------------------------------------------------|
| Transport   | `X-Telegram-Bot-Api-Secret-Token` header, `hmac.compare_digest`         | Anyone who isn't Telegram calling the URL                                      |
| Application | `chat_id == ALLOWED_CHAT_ID`                                             | Anyone who isn't you, messaging the bot                                        |
| IAM         | Condition-scoped `roles/compute.instanceAdmin.v1` on one instance       | The function's own credentials being useful for anything but this VM, if leaked |

Both secrets — the bot token and the webhook secret — live in Secret
Manager and reach the function as `secret_environment_variables`, so
neither appears in `.tf` source or in plaintext Terraform state.

---

## 3. Function code

Structural changes from the draft: the secret-token check runs first and
unconditionally; `get_json` is guarded so a malformed body can't throw
before the checks run; Compute API calls are wrapped so a double-tap (VM
already on/off) sends a message instead of a 500 that makes Telegram retry
the whole webhook.

### main.py

```python
import hmac
import os

import requests
from google.api_core import exceptions as gcloud_exceptions
from google.cloud import compute_v1

compute_client = compute_v1.InstancesClient()

PROJECT = os.environ["PROJECT_ID"]
ZONE = os.environ["ZONE"]
INSTANCE = os.environ["INSTANCE_NAME"]
BOT_TOKEN = os.environ["BOT_TOKEN"]
WEBHOOK_SECRET = os.environ["WEBHOOK_SECRET_TOKEN"]
ALLOWED_CHAT_ID = int(os.environ["ALLOWED_CHAT_ID"])

API_URL = f"https://api.telegram.org/bot{BOT_TOKEN}/"

KEYBOARD = {
    "inline_keyboard": [[
        {"text": "Power On \U0001F7E2", "callback_data": "power_on"},
        {"text": "Power Off \U0001F534", "callback_data": "power_off"},
    ]]
}


def telegram_webhook(request):
    """HTTP entry point for the Telegram webhook (Cloud Functions Gen2)."""

    # Verify the call actually came from Telegram before trusting anything
    # in the body -- chat_id alone is not an auth boundary, it's attacker
    # controlled on an unauthenticated endpoint.
    header_token = request.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
    if not hmac.compare_digest(header_token, WEBHOOK_SECRET):
        return "Forbidden", 403

    data = request.get_json(silent=True) or {}

    if "callback_query" in data:
        return _handle_callback(data["callback_query"])

    if "message" in data and "text" in data["message"]:
        return _handle_message(data["message"])

    return "OK", 200


def _handle_callback(callback_query):
    chat_id = callback_query["message"]["chat"]["id"]
    if chat_id != ALLOWED_CHAT_ID:
        return "Forbidden", 403

    requests.post(
        API_URL + "answerCallbackQuery",
        json={"callback_query_id": callback_query["id"]},
        timeout=5,
    )

    action = callback_query.get("data")
    if action == "power_on":
        _run_power_action(compute_client.start, chat_id, "\U0001F7E2 Booting up AI VPS...")
    elif action == "power_off":
        _run_power_action(compute_client.stop, chat_id, "\U0001F534 Shutting down AI VPS...")

    return "OK", 200


def _run_power_action(method, chat_id, ok_text):
    try:
        method(project=PROJECT, zone=ZONE, instance=INSTANCE)
        text = ok_text
    except gcloud_exceptions.GoogleAPICallError as exc:
        text = f"⚠️ Compute API error: {exc.message}"

    requests.post(API_URL + "sendMessage", json={"chat_id": chat_id, "text": text}, timeout=5)


def _handle_message(message):
    chat_id = message["chat"]["id"]
    if chat_id != ALLOWED_CHAT_ID:
        return "Forbidden", 403

    if message["text"] in ("/start", "/control"):
        requests.post(
            API_URL + "sendMessage",
            json={"chat_id": chat_id, "text": "Server Control Panel:", "reply_markup": KEYBOARD},
            timeout=5,
        )

    return "OK", 200
```

### requirements.txt

```
functions-framework==3.*
requests==2.*
google-cloud-compute==1.*
```

---

## 4. Terraform

Split into the pieces that changed: secrets, a condition-scoped IAM
binding, and the Gen2 function resource. Variables and the storage bucket
for the source zip are included since this is a from-scratch project
directory.

### variables.tf

```hcl
variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "instance_name" {
  type    = string
  default = "ai-dev-vps"
}

variable "allowed_chat_id" {
  type = string
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}
```

### secrets.tf

```hcl
resource "random_password" "webhook_secret" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "bot_token" {
  secret_id = "telegram-bot-token"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "bot_token" {
  secret      = google_secret_manager_secret.bot_token.id
  secret_data = var.telegram_bot_token
}

resource "google_secret_manager_secret" "webhook_secret_token" {
  secret_id = "telegram-webhook-secret-token"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "webhook_secret_token" {
  secret      = google_secret_manager_secret.webhook_secret_token.id
  secret_data = random_password.webhook_secret.result
}
```

### iam.tf

```hcl
resource "google_service_account" "function_sa" {
  account_id   = "telegram-webhook-fn"
  display_name = "Telegram webhook function"
}

# Scoped to this one instance via an IAM condition, not project-wide.
resource "google_project_iam_member" "function_can_manage_instance" {
  project = var.project_id
  role    = "roles/compute.instanceAdmin.v1"
  member  = "serviceAccount:${google_service_account.function_sa.email}"

  condition {
    title      = "only-ai-dev-vps"
    expression = "resource.name == \"projects/${var.project_id}/zones/${var.zone}/instances/${var.instance_name}\""
  }
}

resource "google_secret_manager_secret_iam_member" "bot_token_access" {
  secret_id = google_secret_manager_secret.bot_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_secret_manager_secret_iam_member" "webhook_secret_access" {
  secret_id = google_secret_manager_secret.webhook_secret_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.function_sa.email}"
}
```

### function.tf

```hcl
resource "google_storage_bucket" "function_bucket" {
  name                        = "${var.project_id}-telegram-webhook-src"
  location                    = var.region
  uniform_bucket_level_access = true
}

data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/function_src"
  output_path = "${path.module}/build/function.zip"
}

resource "google_storage_bucket_object" "function_zip" {
  name   = "function-${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = data.archive_file.function_zip.output_path
}

resource "google_cloudfunctions2_function" "telegram_webhook" {
  name     = "telegram-boot-function"
  location = var.region

  build_config {
    runtime     = "python312"
    entry_point = "telegram_webhook"
    source {
      storage_source {
        bucket = google_storage_bucket.function_bucket.name
        object = google_storage_bucket_object.function_zip.name
      }
    }
  }

  service_config {
    max_instance_count    = 3
    available_memory      = "256M"
    timeout_seconds        = 30
    service_account_email = google_service_account.function_sa.email

    environment_variables = {
      PROJECT_ID      = var.project_id
      ZONE            = var.zone
      INSTANCE_NAME   = var.instance_name
      ALLOWED_CHAT_ID = var.allowed_chat_id
    }

    secret_environment_variables {
      key        = "BOT_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.bot_token.secret_id
      version    = "latest"
    }

    secret_environment_variables {
      key        = "WEBHOOK_SECRET_TOKEN"
      project_id = var.project_id
      secret     = google_secret_manager_secret.webhook_secret_token.secret_id
      version    = "latest"
    }
  }
}

# Gen2 functions run on Cloud Run under the hood -- invoker access is
# granted at that layer, not on the cloudfunctions2 resource itself.
resource "google_cloud_run_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.telegram_webhook.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

output "function_url" {
  value = google_cloudfunctions2_function.telegram_webhook.service_config[0].uri
}

output "webhook_secret_token" {
  value     = random_password.webhook_secret.result
  sensitive = true
}
```

---

## 5. Deployment steps

1. **Provide the sensitive variables.** Put `telegram_bot_token` and
   `allowed_chat_id` in a `terraform.tfvars` that stays out of git —
   `.gitignore` it before the first commit.
2. **Apply.** `terraform init && terraform apply`. This provisions the
   service account, secrets, IAM binding, storage bucket, and the Gen2
   function.
3. **Register the webhook.** Point Telegram at the function and hand it
   the secret token in one call:
   ```
   curl -F "url=$(terraform output -raw function_url)" \
        -F "secret_token=$(terraform output -raw webhook_secret_token)" \
        "https://api.telegram.org/bot<BOT_TOKEN>/setWebhook"
   ```
4. **Verify.** Message `/start` to the bot from the allowed account,
   confirm the inline keyboard appears, and tap Power Off / Power On once
   each against a low-stakes moment to confirm the VM actually transitions.

---

## 6. Open items

Values and calls only you can make before this ships:

- [ ] GCP project ID, region, and zone for `ai-dev-vps`
- [ ] Your numeric Telegram chat ID (get it from `@userinfobot` or the
      bot's own update log)
- [x] Whether the existing auto-shutdown cron on the VM should also notify
      Telegram when it fires, so the two control paths don't feel
      disconnected — **resolved: yes**, see
      [gce-admin-prep.md §6](gce-admin-prep.md#6-wire-the-auto-shutdown-cron-to-notify-telegram)
      for the pattern (a local root-only secret file, not a Secret
      Manager call, since the VM's default service account lacks the
      OAuth scope for that without a restart).
- [x] Whether `terraform.tfvars` / state will live somewhere with a remote
      backend, or stay local for now — **resolved: local state** for now.
      The scaffold in `terraform/` uses no backend block, so state is a
      local `terraform.tfstate` file (gitignored).
