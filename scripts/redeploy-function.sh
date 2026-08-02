#!/usr/bin/env bash
# Redeploys the telegram-boot-function Cloud Function directly from source,
# bypassing Terraform. Values are read from terraform/terraform.tfvars
# (gitignored) rather than hardcoded, since chat_id/project_id shouldn't
# live in a tracked file. Fixed values (region/zone/instance name/service
# account/memory/timeout) mirror terraform/function.tf and
# terraform/variables.tf -- keep them in sync if those change.
#
# Re-run this after any `terraform apply` that touches
# google_cloudfunctions2_function.telegram_webhook -- Terraform doesn't
# know about deploys made this way and will otherwise revert the source
# on its next apply.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"
SOURCE_DIR="${REPO_ROOT}/terraform/function_src"

FUNCTION_NAME="telegram-boot-function"
REGION="us-central1"
ZONE="us-central1-a"
INSTANCE_NAME="ai-dev-vps"

tfvar() {
  local key="$1"
  sed -nE "s/^\s*${key}\s*=\s*\"([^\"]*)\".*/\1/p" "$TFVARS" | head -n1
}

if [[ ! -f "$TFVARS" ]]; then
  echo "Missing $TFVARS -- copy terraform/terraform.tfvars.example and fill it in first." >&2
  exit 1
fi

PROJECT_ID="$(tfvar project_id)"
ALLOWED_CHAT_ID="$(tfvar allowed_chat_id)"

if [[ -z "$PROJECT_ID" || -z "$ALLOWED_CHAT_ID" ]]; then
  echo "Could not read project_id/allowed_chat_id from $TFVARS" >&2
  exit 1
fi

SERVICE_ACCOUNT="telegram-webhook-fn@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Deploying ${FUNCTION_NAME} in ${PROJECT_ID}/${REGION} from ${SOURCE_DIR}..."

gcloud functions deploy "$FUNCTION_NAME" \
  --gen2 \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --runtime=python312 \
  --entry-point=telegram_webhook \
  --source="$SOURCE_DIR" \
  --trigger-http \
  --allow-unauthenticated \
  --service-account="$SERVICE_ACCOUNT" \
  --memory=256Mi \
  --timeout=30s \
  --max-instances=3 \
  --set-env-vars="PROJECT_ID=${PROJECT_ID},ZONE=${ZONE},INSTANCE_NAME=${INSTANCE_NAME},ALLOWED_CHAT_ID=${ALLOWED_CHAT_ID}" \
  --set-secrets="BOT_TOKEN=telegram-bot-token:latest,WEBHOOK_SECRET_TOKEN=telegram-webhook-secret-token:latest"
