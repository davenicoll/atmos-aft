locals {
  enabled = module.this.enabled
}

resource "aws_iam_account_password_policy" "this" {
  count = local.enabled && var.manage_password_policy ? 1 : 0

  minimum_password_length        = var.password_minimum_length
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  hard_expiry                    = false
  max_password_age               = var.password_max_age
  password_reuse_prevention      = var.password_reuse_prevention
}

resource "aws_ebs_encryption_by_default" "this" {
  count = local.enabled && var.manage_ebs_encryption ? 1 : 0

  enabled = true
}

resource "aws_ebs_default_kms_key" "this" {
  count = local.enabled && var.manage_ebs_encryption && var.ebs_default_kms_key_id != null ? 1 : 0

  key_arn = var.ebs_default_kms_key_id
}
