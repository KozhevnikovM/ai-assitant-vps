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
