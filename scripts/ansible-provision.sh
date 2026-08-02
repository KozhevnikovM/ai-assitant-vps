#!/usr/bin/env bash
#
# Runs ansible/playbook.yml against a GCE instance reachable only through
# an IAP tunnel. Called by terraform/vm_setup.tf's local-exec provisioner,
# but safe to run standalone for debugging -- just export the same env
# vars terraform passes it:
#
#   PROJECT_ID=... ZONE=... INSTANCE_NAME=ai-dev-vps \
#     BOT_TOKEN=... CHAT_ID=... ./scripts/ansible-provision.sh
#
# This gcloud version has no `--listen-on-stdin` flag on
# `start-iap-tunnel` (the usual ProxyCommand pattern), so instead: start
# the tunnel in the background on a fixed local port, wait for it to
# accept connections, run the playbook against that port, then kill the
# tunnel.

set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID is required}"
: "${ZONE:?ZONE is required}"
: "${INSTANCE_NAME:?INSTANCE_NAME is required}"
: "${BOT_TOKEN:?BOT_TOKEN is required}"
: "${CHAT_ID:?CHAT_ID is required}"

LOCAL_PORT=2222
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

status=$(gcloud compute instances describe "$INSTANCE_NAME" \
  --project="$PROJECT_ID" --zone="$ZONE" --format='value(status)')
if [ "$status" != "RUNNING" ]; then
  echo "error: $INSTANCE_NAME is $status, not RUNNING -- can't provision it right now" >&2
  exit 1
fi

gcloud compute start-iap-tunnel "$INSTANCE_NAME" 22 \
  --local-host-port="localhost:${LOCAL_PORT}" \
  --project="$PROJECT_ID" --zone="$ZONE" &
TUNNEL_PID=$!
trap 'kill "$TUNNEL_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
  if bash -c "echo >/dev/tcp/127.0.0.1/${LOCAL_PORT}" 2>/dev/null; then
    break
  fi
  sleep 1
done

cd "$REPO_ROOT"
ansible-playbook -i ansible/inventory.ini ansible/playbook.yml \
  -e telegram_bot_token="$BOT_TOKEN" \
  -e telegram_chat_id="$CHAT_ID"
