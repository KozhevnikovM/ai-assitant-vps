# GCE admin prep — before we run `terraform apply`

Handoff doc for whoever administers the GCP project. Most of this is
one-time project setup so the Terraform in [plan.md](plan.md) applies
without surprises — the one exception is §6, where `terraform apply`
itself now reaches the `ai-dev-vps` instance over an IAP-tunneled SSH
connection to provision it (see [server-setup.md](server-setup.md)).

---

## 1. Confirm the target project and instance

We need these values filled in (they go into `terraform.tfvars`):

- [ ] **Project ID** hosting `ai-dev-vps`
- [ ] **Region** the function should run in (plan defaults to `us-central1`)
- [ ] **Zone** the VM is actually in (plan defaults to `us-central1-a`)
- [ ] Confirm the instance name really is `ai-dev-vps` (or tell us the real
      name — it's a Terraform variable either way)
- [ ] **Billing** is enabled on the project (Cloud Functions Gen2 and Cloud
      Build both require it)

## 2. Enable APIs

Gen2 Cloud Functions build via Cloud Build and store images in Artifact
Registry, so it's more than just the Functions API. Run:

```
gcloud services enable \
  cloudfunctions.googleapis.com \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  compute.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project=<PROJECT_ID>
```

(`compute.googleapis.com` is presumably already on, since the VM exists —
worth a quick check rather than assuming.)

## 3. Grant IAM to whoever runs `terraform apply`

Terraform will be creating a service account, an IAM binding with a
condition, secrets, a storage bucket, and a Cloud Functions Gen2 resource
with Cloud Run invoker access. Rather than handing out several `*.admin`
predefined roles, a custom role scoped to exactly those permissions is
tighter and easy to revoke as one unit afterward.

Create the role:

```
gcloud iam roles create terraformTelegramWebhookDeployer \
  --project=<PROJECT_ID> \
  --title="Terraform - telegram webhook deployer" \
  --description="One-time apply role for the telegram-boot-function stack" \
  --stage=GA \
  --permissions=resourcemanager.projects.get,resourcemanager.projects.getIamPolicy,resourcemanager.projects.setIamPolicy,iam.serviceAccounts.create,iam.serviceAccounts.get,iam.serviceAccounts.delete,iam.serviceAccounts.list,iam.serviceAccounts.actAs,secretmanager.secrets.create,secretmanager.secrets.get,secretmanager.secrets.delete,secretmanager.secrets.list,secretmanager.secrets.getIamPolicy,secretmanager.secrets.setIamPolicy,secretmanager.versions.add,secretmanager.versions.get,secretmanager.versions.list,secretmanager.versions.destroy,storage.buckets.create,storage.buckets.get,storage.buckets.delete,storage.buckets.list,storage.objects.create,storage.objects.get,storage.objects.delete,storage.objects.list,cloudfunctions.functions.create,cloudfunctions.functions.get,cloudfunctions.functions.update,cloudfunctions.functions.delete,cloudfunctions.functions.list,cloudfunctions.operations.get,run.services.get,run.services.list,run.services.getIamPolicy,run.services.setIamPolicy,compute.instances.get,iap.tunnelInstances.accessViaIAP
```

If `apply` should run as a dedicated identity rather than a human account
(recommended if this will ever run from CI, or just to keep the elevated
role off a personal account), create the deployer service account first:

```
gcloud iam service-accounts create terraform-deployer \
  --project=<PROJECT_ID> \
  --display-name="Terraform deployer for telegram webhook stack"
```

Then let yourself (or whoever runs `apply`) impersonate it, rather than
handing out a downloaded key file — keys are long-lived and easy to lose
track of, impersonation tokens expire and are revoked by removing one
binding:

```
gcloud iam service-accounts add-iam-policy-binding \
  terraform-deployer@<PROJECT_ID>.iam.gserviceaccount.com \
  --member="user:<YOUR_EMAIL>" \
  --role="roles/iam.serviceAccountTokenCreator"

gcloud auth application-default login \
  --impersonate-service-account=terraform-deployer@<PROJECT_ID>.iam.gserviceaccount.com
```

If a key file is genuinely required (e.g. a CI system with no
impersonation support), `gcloud iam service-accounts keys create key.json
--iam-account=terraform-deployer@<PROJECT_ID>.iam.gserviceaccount.com`
works, but treat the file as a secret — never commit it, and rotate/delete
it once the stack is applied.

Bind the custom role to whichever identity — human or service account —
runs `apply`:

```
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member="user:<DEPLOYER_EMAIL>" \
  --role="projects/<PROJECT_ID>/roles/terraformTelegramWebhookDeployer"
```

(swap `user:<DEPLOYER_EMAIL>` for
`serviceAccount:terraform-deployer@<PROJECT_ID>.iam.gserviceaccount.com` if
using the dedicated deployer service account above).

Notes on the permission list:

- `resourcemanager.projects.setIamPolicy` is what grants the
  condition-scoped `compute.instanceAdmin.v1` binding — Terraform's own
  resource graph never calls the Compute API directly, only sets IAM on
  the project.
- `iam.serviceAccounts.actAs` lets the deployer impersonate the new
  function service account during deployment; drop it if deploys ever
  start failing with an impersonation error and add it back.
- `compute.instances.get` and `iap.tunnelInstances.accessViaIAP` are for
  `null_resource.vm_setup` (§6 / server-setup.md), *not* the rest of the
  stack — that's `terraform apply` itself reaching the VM over an
  IAP-tunneled SSH connection to run Ansible, the one place this stack
  touches the Compute API at all.
- Nothing from `cloudbuild.googleapis.com` or
  `artifactregistry.googleapis.com` is listed — the underlying build that
  Cloud Functions Gen2 triggers runs under Google's own service agent, not
  the caller's identity.

Once the stack is applied and stable, this role can be revoked from the
deployer (`gcloud projects remove-iam-policy-binding ...`) without deleting
it, and re-bound only when a future `apply` is needed.

If a custom role is more process than this project wants, the predefined
equivalent is `roles/editor` plus `roles/resourcemanager.projectIamAdmin`
for a one-time apply, revoked afterward — coarser, but zero setup.

## 4. Decide where Terraform state lives

Plan currently assumes local state. If this project already has a
convention (a shared GCS backend bucket, etc.), let us know the bucket name
and we'll wire up the backend block before the first apply — switching
backends after the fact means a state migration, better to settle it now.

## 5. Values only you can provide

These aren't infrastructure prep, just information we need from you to
fill in `terraform.tfvars` (which stays out of git):

- [ ] `project_id`, `region`, `zone` from step 1
- [ ] Telegram bot token (from `@BotFather` — create the bot if it doesn't
      exist yet)
- [ ] The allowed numeric Telegram chat ID (from `@userinfobot`)

---

## 6. Auto-shutdown cron + Telegram notify

`terraform apply` now installs this automatically —
`terraform/vm_setup.tf`'s `null_resource.vm_setup` runs
[`ansible/playbook.yml`](../../ansible/playbook.yml) against the instance
over an IAP-tunneled SSH connection (via
[`scripts/ansible-provision.sh`](../../scripts/ansible-provision.sh)), no
manual step required. See [server-setup.md](server-setup.md) for the full
design and how to run it standalone if you need to debug it.

This is why the custom role in §3 includes `compute.instances.get` and
`iap.tunnelInstances.accessViaIAP` — that's what this step needs to open
the tunnel.

Short version of the design: the script notifies Telegram from a
root-only local secret file rather than calling Secret Manager directly,
because most default Compute Engine service accounts have legacy OAuth
scopes (`devstorage.read_only`, `logging.write`, etc.) rather than
`cloud-platform`, and widening that means stopping and restarting the
instance. The tradeoff is a second copy of the bot token living outside
Secret Manager. See server-setup.md for the full rationale and steps.

---

## Not needed

- No manual SSH/scp to the instance — `terraform apply` handles the
  idle-shutdown + Telegram-notify setup itself (§6).
- No manual secret creation — Terraform creates both Secret Manager
  entries; you're only supplying the raw bot token value as a tfvar.
- No manual webhook registration — that's a `curl` call after `apply`,
  covered in plan.md step 5.3.
