# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

This repository currently contains **planning documentation only** — no
Terraform, Python, or other source files have been committed or applied
yet. The infrastructure design lives entirely inside `docs/mvp/plan.md` as
embedded code blocks (Terraform `.tf` files and a Cloud Function `main.py`)
that describe what will eventually be created, not files that exist on
disk. When asked to "implement" or "apply" this project, the first step is
materializing those embedded blocks into real files (e.g. a
`terraform/` or `function_src/` directory) — check with the user on
layout before assuming one.

There are no build, lint, or test commands yet because there is no code to
build, lint, or test.

## What this project is

A Telegram-controlled power switch for a Compute Engine VM
(`ai-dev-vps`): a Cloud Functions Gen2 webhook, triggered by inline-button
taps in Telegram from one authorized user, starts or stops the instance.

- **[docs/mvp/plan.md](docs/mvp/plan.md)** — the finalized architecture and
  design rationale. Read this fully before making any infra decision; it
  documents *why* choices were made (e.g. a security gap found and fixed
  in an earlier draft — see its "Security model" section — is the reason
  the webhook is authenticated via Telegram's `secret_token` header before
  `chat_id` is ever trusted). Contains the full intended Terraform module
  (`variables.tf`, `secrets.tf`, `iam.tf`, `function.tf`) and the Cloud
  Function source (`main.py`, `requirements.txt`).
- **[docs/mvp/gce-admin-prep.md](docs/mvp/gce-admin-prep.md)** — the
  one-time GCP project setup a project admin must do before `terraform
  apply` can run cleanly: which APIs to enable, a minimal custom IAM role
  scoped to exactly what this Terraform stack needs (rather than
  predefined `*.admin` roles), and how to set up a dedicated deployer
  service account via impersonation rather than a downloaded key.
- **[docs/mvp/implementation-steps.md](docs/mvp/implementation-steps.md)**
  — the current step-by-step path from plan.md's design to a deployed
  MVP, each step linked to its tracking issue (see below).

## Architecture (from plan.md)

```
Telegram (inline button tap)
  --HTTPS POST + secret header-->
Cloud Functions Gen2 webhook
  1. verifies X-Telegram-Bot-Api-Secret-Token (hmac.compare_digest)
  2. verifies chat_id against ALLOWED_CHAT_ID
  3. calls compute_v1.InstancesClient().start()/stop()
  --compute.instances API-->
ai-dev-vps (e2-medium Compute Engine instance)
```

Three independent auth layers, narrowest first: the Telegram secret-token
header (transport), the `chat_id` allowlist (application), and a
condition-scoped `roles/compute.instanceAdmin.v1` IAM binding restricting
the function's service account to only this one instance (IAM). Both the
bot token and the webhook secret are stored in Secret Manager and injected
via `secret_environment_variables` — never in `.tf` source or Terraform
state.

## Planning workflow

Before implementing a multi-step piece of work in this repo, write the
step-by-step plan to a doc under `docs/mvp/` (e.g.
`docs/mvp/implementation-steps.md`) rather than only using an ephemeral
plan-mode file — it's a durable, reviewable artifact the user can revisit
across sessions. Then create one GitHub issue per step (`gh issue
create`), and add a link back to each issue next to its step heading in
the doc, so the plan doc and the issue tracker cross-reference each other.
Do not start executing steps until the user says to proceed.

## Working conventions established in this repo

- Never add a `Co-Authored-By: Claude` trailer to commits, or a
  "Generated with Claude Code" footer to PR descriptions, in this
  repository.
- Never push directly to `main`. Work on a feature branch and open a PR,
  even for small changes.
