# Installs the idle-shutdown script + Telegram notify config on the
# target instance via Ansible (scripts/ansible-provision.sh). The VM
# itself is deliberately not a Terraform-managed resource -- see
# function.tf/iam.tf, which only grant the function's service account
# permission to start/stop it by name -- so this reaches it out-of-band
# over an IAP-tunneled SSH connection instead of a native provider
# resource.
resource "null_resource" "vm_setup" {
  triggers = {
    playbook_sha256  = filesha256("${path.module}/../ansible/playbook.yml")
    template_sha256  = filesha256("${path.module}/../ansible/templates/telegram-notify.env.j2")
    script_sha256    = filesha256("${path.module}/../scripts/idle-shutdown.sh")
    bot_token_sha256 = sha256(var.telegram_bot_token)
    chat_id          = var.allowed_chat_id
    instance_name    = var.instance_name
  }

  provisioner "local-exec" {
    command     = "scripts/ansible-provision.sh"
    working_dir = "${path.module}/.."
    environment = {
      PROJECT_ID    = var.project_id
      ZONE          = var.zone
      INSTANCE_NAME = var.instance_name
      BOT_TOKEN     = var.telegram_bot_token
      CHAT_ID       = var.allowed_chat_id
    }
  }
}
