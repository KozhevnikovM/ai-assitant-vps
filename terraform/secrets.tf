resource "random_password" "webhook_secret" {
  length  = 32
  special = false
}

resource "google_secret_manager_secret" "bot_token" {
  secret_id = "telegram-bot-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "bot_token" {
  secret      = google_secret_manager_secret.bot_token.id
  secret_data = var.telegram_bot_token
}

resource "google_secret_manager_secret" "webhook_secret_token" {
  secret_id = "telegram-webhook-secret-token"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "webhook_secret_token" {
  secret      = google_secret_manager_secret.webhook_secret_token.id
  secret_data = random_password.webhook_secret.result
}
