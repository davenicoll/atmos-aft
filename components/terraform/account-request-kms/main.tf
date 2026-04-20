module "kms_key" {
  source  = "cloudposse/kms-key/aws"
  version = "0.12.2"

  description             = var.description
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true
  alias                   = var.alias
  policy                  = var.policy

  context = module.this.context
}
