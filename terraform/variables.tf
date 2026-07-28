variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "instance_name" {
  type    = string
  default = "ai-dev-vps"
}

variable "allowed_chat_id" {
  type = string
}

variable "telegram_bot_token" {
  type      = string
  sensitive = true
}
