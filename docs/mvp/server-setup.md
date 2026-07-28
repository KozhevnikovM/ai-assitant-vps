# Server setup: idle-shutdown + Telegram notify

How to install the auto-shutdown cron and its Telegram notification on the
`ai-dev-vps` instance. This is a manual, one-time step per VM — it isn't
managed by the `terraform/` module (that module only grants the Cloud
Function IAM permission to start/stop the instance by name; it doesn't
touch the instance's own filesystem or cron).

Verified working end-to-end against a real deployment (`ai-vps-503813`)
before being written up here.

## Prerequisites

- The target VM exists and you can reach it: `gcloud compute ssh
  <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap`
- The Terraform stack in `terraform/` is already applied — you'll reuse
  the same bot token and chat ID from `terraform.tfvars` here.

## 1. Copy the script to the VM

```
gcloud compute scp scripts/idle-shutdown.sh \
  <instance>:/tmp/idle-shutdown.sh \
  --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap

gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  sudo mkdir -p /home/mike/infra
  sudo mv /tmp/idle-shutdown.sh /home/mike/infra/idle-shutdown.sh
  sudo chmod +x /home/mike/infra/idle-shutdown.sh
  sudo chown root:root /home/mike/infra/idle-shutdown.sh
'
```

(Adjust `/home/mike/infra` if the VM uses a different convention — the
crontab entry in step 3 just needs to match wherever you put it.)

## 2. Create the Telegram secret file

Copy `scripts/telegram-notify.env.example`, fill in the same bot token
and chat ID used in `terraform.tfvars`, and install it root-owned and
unreadable by anyone else:

```
gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  sudo install -m 600 -o root -g root /dev/null /etc/telegram-notify.env
  sudo tee /etc/telegram-notify.env >/dev/null <<EOF
TELEGRAM_BOT_TOKEN=<same token as terraform.tfvars telegram_bot_token>
TELEGRAM_CHAT_ID=<same value as terraform.tfvars allowed_chat_id>
EOF
'
```

Why a second copy of the token instead of reading it from Secret Manager:
the VM's default service account typically has legacy OAuth scopes
(`devstorage.read_only`, `logging.write`, etc.) rather than
`cloud-platform`, which Secret Manager calls require. Widening the scope
means detaching and reattaching the service account, which requires
stopping the instance — more disruptive than a second, VM-local secret
file for this use case.

## 3. Install the cron job

```
gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  (sudo crontab -l 2>/dev/null; echo "* * * * * /home/mike/infra/idle-shutdown.sh") | sudo crontab -
'
```

`IDLE_MINUTES` defaults to 30 inside the script; override by exporting it
before the cron line if you want a different threshold, e.g.:
`*/1 * * * * IDLE_MINUTES=10 /home/mike/infra/idle-shutdown.sh`.

## 4. Verify

Check the crontab is in place and the script is logging each run:

```
gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  sudo crontab -l
  sudo tail -5 /var/log/idle-shutdown.log
'
```

Test the Telegram notification directly, without waiting for a real idle
timeout or actually shutting the instance down:

```
gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  sudo bash -c "source /home/mike/infra/idle-shutdown.sh 2>/dev/null; notify_telegram"
  sudo rm -f /var/tmp/idle-shutdown.state
'
```

You should get "🔴 ai-dev-vps auto-shutdown: idle timeout reached" in
Telegram. The `rm -f` afterward clears the idle-timer state that sourcing
the script starts as a side effect, so cron begins counting fresh instead
of inheriting a stray partial timer from this test.
