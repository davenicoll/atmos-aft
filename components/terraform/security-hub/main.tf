module "security_hub" {
  source  = "cloudposse/security-hub/aws"
  version = "0.12.2"

  enabled_standards                 = var.enabled_standards
  create_organization_admin_account = false # handled externally — see README
  finding_aggregator_enabled        = var.finding_aggregator_enabled
  finding_aggregator_linking_mode   = var.finding_aggregator_linking_mode
  finding_aggregator_regions        = var.finding_aggregator_regions

  context = module.this.context
}

# Delegated-admin assignment lives outside the module because the module
# does not expose `aws_securityhub_organization_admin_account` in v0.12.2.
# Only set from the org management account.
resource "aws_securityhub_organization_admin_account" "this" {
  count = module.this.enabled && var.set_delegated_admin_account_id != null ? 1 : 0

  admin_account_id = var.set_delegated_admin_account_id
}
