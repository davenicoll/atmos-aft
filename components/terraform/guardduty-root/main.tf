# Phase 1 of 3. Registers the security/audit account as GuardDuty delegated admin.
# Runs in the organization management account.

locals {
  enabled = module.this.enabled
}

resource "aws_guardduty_organization_admin_account" "this" {
  count = local.enabled ? 1 : 0

  admin_account_id = var.delegated_admin_account_id

  lifecycle {
    precondition {
      condition     = can(regex("^[0-9]{12}$", var.delegated_admin_account_id))
      error_message = "delegated_admin_account_id must be a 12-digit account ID."
    }
  }
}
