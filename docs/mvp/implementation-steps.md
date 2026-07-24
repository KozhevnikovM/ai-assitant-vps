# MVP implementation steps

Step-by-step path from `plan.md`'s finalized design to a deployed,
working Telegram power switch. Each step is small enough to review and
commit on its own.

Two decisions locked in for this pass (superseding plan.md §6's open
items on these two points):

| Open item | Resolution |
|---|---|
| Terraform state backend | Local state for now, not a remote GCS backend |
| Cron auto-shutdown → Telegram notify | In scope for this MVP, not deferred |

---

## 1. Branch — [#2](https://github.com/KozhevnikovM/ai-assitant-vps/issues/2)

Create `feat/terraform-scaffold` off `main`. Never commit straight to
`main` (see [CLAUDE.md](../../CLAUDE.md)).

## 2. Scaffold the Terraform module — `terraform/` — [#3](https://github.com/KozhevnikovM/ai-assitant-vps/issues/3)

Materialize plan.md §4's embedded code blocks as real files, plus one
file plan.md didn't include:

- `terraform/versions.tf` — **new**. `required_providers` (`google`,
  `random`, `archive`) and a `provider "google"` block using
  `var.project_id` / `var.region`. Plan.md's snippets were "the pieces
  that changed," not a complete module — without this, `terraform init`
  has nothing to install.
- `terraform/variables.tf`, `secrets.tf`, `iam.tf`, `function.tf` — from
  plan.md §4, verbatim.
- `terraform/function_src/main.py`, `requirements.txt` — from plan.md §3,
  verbatim.
- `terraform/terraform.tfvars.example` — **new**. Template with
  placeholder values and one comment per variable. Safe to commit, no
  real values.
- `terraform/.gitignore` — **new**. Ignores `.terraform/`, `*.tfstate*`,
  `terraform.tfvars`, `build/`. `.terraform.lock.hcl` stays tracked once
  `init` generates it.

## 3. Validate the scaffold locally — [#4](https://github.com/KozhevnikovM/ai-assitant-vps/issues/4)

`cd terraform && terraform init && terraform validate`. This only
downloads provider plugins from the public registry and checks syntax —
no GCP credentials or live project required, so it's safe to run
immediately and catches transcription mistakes before any admin touches
it.

## 4. Document the cron → Telegram notify step — [#5](https://github.com/KozhevnikovM/ai-assitant-vps/issues/5)

Documentation only, not a code change — the real auto-shutdown script
lives on the actual `ai-dev-vps` VM, outside this repo's reach. Add a new
section to [gce-admin-prep.md](gce-admin-prep.md) giving the admin a
ready-to-adapt pattern:

- Create `/etc/telegram-notify.env` on the VM, root-owned and
  `chmod 600`, holding `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`. This
  duplicates the bot token outside Secret Manager — an accepted tradeoff:
  the alternative (granting the VM's service account
  `secretmanager.secretAccessor` and calling Secret Manager directly)
  needs a `cloud-platform` OAuth scope most default service accounts
  don't have, and adding it means stopping and restarting the VM.
- A `notify_telegram()` shell function (sources that env file, `curl`s
  Telegram's `sendMessage`) plus one call site: right before whatever
  line currently shuts the instance down.

## 5. Close out plan.md's open items — [#6](https://github.com/KozhevnikovM/ai-assitant-vps/issues/6)

Update plan.md §6: check off the state-backend item (resolved: local)
and the cron-notify item (resolved: documented in gce-admin-prep.md per
step 4 above), so the doc reflects current decisions instead of going
stale.

## 6. Commit and open a PR — [#7](https://github.com/KozhevnikovM/ai-assitant-vps/issues/7)

Same workflow as the first docs PR: commit the scaffold on
`feat/terraform-scaffold`, push, open a PR against `main`. No
Claude/Claude Code attribution in the commit or PR body.

---

## Explicitly out of scope for this pass

- Filling real values into `terraform.tfvars` (project ID, chat ID, bot
  token) — admin-supplied, stays gitignored.
- Running `terraform plan`/`apply` against the real project — needs live
  credentials for the actual target project.
- Registering the Telegram webhook and end-to-end verification — plan.md
  §5 already covers these as post-apply manual steps.
- Actually editing the real `ai-dev-vps` shutdown script — step 4
  produces the instructions the admin applies, not the edit itself.

## Verification

- `terraform init && terraform validate` in `terraform/` exits clean.
- The PR diff shows exactly the new `terraform/` tree plus the two doc
  updates — no unrelated changes.
