# Vanilla Inspector2 composition. Three shapes driven by `role`:
#   - "management"    → set delegated admin, nothing else
#   - "delegated"     → org-level config + enabler
#   - "member"        → per-member association

locals {
  enabled   = module.this.enabled
  is_mgmt   = var.role == "management"
  is_deleg  = var.role == "delegated"
  is_member = var.role == "member"
}

resource "aws_inspector2_delegated_admin_account" "this" {
  count = local.enabled && local.is_mgmt ? 1 : 0

  account_id = var.delegated_admin_account_id
}

resource "aws_inspector2_organization_configuration" "this" {
  count = local.enabled && local.is_deleg ? 1 : 0

  auto_enable {
    ec2         = var.auto_enable_ec2
    ecr         = var.auto_enable_ecr
    lambda      = var.auto_enable_lambda
    lambda_code = var.auto_enable_lambda_code
  }
}

resource "aws_inspector2_enabler" "this" {
  count = local.enabled && local.is_deleg ? 1 : 0

  account_ids    = var.enabler_account_ids
  resource_types = var.enabler_resource_types
}

resource "aws_inspector2_member_association" "this" {
  count = local.enabled && local.is_member ? 1 : 0

  account_id = var.member_account_id
}
