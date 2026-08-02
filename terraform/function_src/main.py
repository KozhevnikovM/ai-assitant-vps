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

POWER_ON_LABEL = "Power On \U0001F7E2"
POWER_OFF_LABEL = "Power Off \U0001F534"

KEYBOARD = {
    "keyboard": [[{"text": POWER_ON_LABEL}, {"text": POWER_OFF_LABEL}]],
    "resize_keyboard": True,
    "is_persistent": True,
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

    if "message" in data and "text" in data["message"]:
        return _handle_message(data["message"])

    return "OK", 200


def _handle_message(message):
    chat_id = message["chat"]["id"]
    if chat_id != ALLOWED_CHAT_ID:
        return "Forbidden", 403

    text = message["text"]

    if text in ("/start", "/control"):
        requests.post(
            API_URL + "sendMessage",
            json={"chat_id": chat_id, "text": "Server Control Panel:", "reply_markup": KEYBOARD},
            timeout=5,
        )
    elif text == POWER_ON_LABEL:
        _run_power_action(compute_client.start, chat_id, "\U0001F7E2 Booting up AI VPS...")
    elif text == POWER_OFF_LABEL:
        _run_power_action(compute_client.stop, chat_id, "\U0001F534 Shutting down AI VPS...")

    return "OK", 200


def _run_power_action(method, chat_id, ok_text):
    try:
        method(project=PROJECT, zone=ZONE, instance=INSTANCE)
        text = ok_text
    except gcloud_exceptions.GoogleAPICallError as exc:
        text = f"⚠️ Compute API error: {exc.message}"

    requests.post(API_URL + "sendMessage", json={"chat_id": chat_id, "text": text}, timeout=5)
