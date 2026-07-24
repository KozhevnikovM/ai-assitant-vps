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
