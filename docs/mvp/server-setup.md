# Server setup: idle-shutdown + Telegram notify

Installs the auto-shutdown cron and its Telegram notification on the
target instance. This runs automatically as part of `terraform apply` —
`terraform/vm_setup.tf`'s `null_resource.vm_setup` calls
`scripts/ansible-provision.sh`, which runs `ansible/playbook.yml` against
the instance over an IAP-tunneled SSH connection.

The VM itself is still not a Terraform-*managed* resource (see
`function.tf`/`iam.tf` — those only grant the Cloud Function's service
account permission to start/stop it by name), so this reaches it
out-of-band via Ansible rather than a native `google_compute_instance`
resource. Verified working end-to-end, including idempotency on a second
apply, against a real deployment (`ai-vps-503813`).

## How it works

| Piece | Role |
|---|---|
| `ansible/playbook.yml` | Copies `scripts/idle-shutdown.sh` to `/home/mike/infra/`, templates `/etc/telegram-notify.env` (root-only, `chmod 600`), and installs the idle-shutdown cron job — all idempotent. |
| `ansible/templates/telegram-notify.env.j2` | Renders the secret file from `telegram_bot_token`/`telegram_chat_id` extra-vars. Task is `no_log: true` so the token never hits Ansible's output. |
| `ansible/inventory.ini` | Static, points at `127.0.0.1:2222` — no secrets or per-environment values, since the wrapper script always forwards the tunnel to that fixed local port. |
| `scripts/ansible-provision.sh` | Starts an IAP tunnel in the background on port 2222, waits for it, runs the playbook, tears the tunnel down on exit. |
| `terraform/vm_setup.tf` | Triggers the script whenever the playbook, template, script, bot token, chat ID, or instance name change. |

Why a second copy of the bot token instead of reading it from Secret
Manager: the VM's default service account typically has legacy OAuth
scopes (`devstorage.read_only`, `logging.write`, etc.) rather than
`cloud-platform`, which Secret Manager calls require. Widening the scope
means detaching and reattaching the service account, which requires
stopping the instance — more disruptive than a second, VM-local secret
file for this use case.

Why Ansible reaches the VM through a backgrounded, fixed-port tunnel
instead of the more commonly documented `ProxyCommand="gcloud compute
start-iap-tunnel %h %p --listen-on-stdin ..."` pattern: this environment's
gcloud SDK (560.0.0) has no `--listen-on-stdin` flag on
`start-iap-tunnel` (checked `--help` on the stable, `alpha`, and `beta`
variants). The fixed-port approach is a couple more moving parts but
doesn't depend on a flag that may not exist in every gcloud version.

## Prerequisites

- `ansible-core` installed locally (alongside `terraform`/`gcloud`) —
  wherever `terraform apply` runs.
- The target VM exists and is `RUNNING` — `ansible-provision.sh` checks
  this and fails fast with a clear message otherwise, rather than hanging
  on a dead tunnel.
- The identity running `terraform apply` can reach the instance via IAP
  (needs `roles/iap.tunnelResourceAccessor` if not using the owner
  account — see `gce-admin-prep.md` §3).
- `gcloud compute ssh` has been run at least once with this identity, so
  `~/.ssh/google_compute_engine` exists and the key is propagated to the
  instance.

## Running it standalone

Useful for debugging without going through a full `terraform apply`:

```
PROJECT_ID=<PROJECT_ID> ZONE=<ZONE> INSTANCE_NAME=<instance> \
  BOT_TOKEN=<telegram_bot_token> CHAT_ID=<allowed_chat_id> \
  ./scripts/ansible-provision.sh
```

## Verify

Check the crontab and files landed correctly:

```
gcloud compute ssh <instance> --project=<PROJECT_ID> --zone=<ZONE> --tunnel-through-iap --command='
  sudo crontab -l
  sudo ls -la /etc/telegram-notify.env /home/mike/infra/idle-shutdown.sh
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
