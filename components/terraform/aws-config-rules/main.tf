# ---------------------------------------------------------------------------
# CONTROL TOWER COEXISTENCE WARNING
# ---------------------------------------------------------------------------
# Only wraps the CIS-1.2 submodule. NEVER use the top-level terraform-aws-config
# module in a CT-enrolled account - it always creates a configuration recorder
# that collides with CT's. See module-inventory.md §5.5.
#
# The cis-1-2-rules submodule itself still declares an
# aws_config_configuration_recorder. On any CT-enrolled account that recorder
# name ("aws-controltower-BaselineConfigRecorder") is already occupied by CT,
# and an apply will fail with "recorder already exists".
#
# Enforcement here is the `var.skip_on_ct_managed_account` flag combined with
# the OPA policies in .github/policies/ (forbidden_components.rego /
# required_ct_flags.rego) - these deny referencing this component from CT-
# managed stacks (account_class in {ct-mgmt, aft-mgmt, audit, log-archive}) at
# PR time. Terraform has no fail-fast data source for "is the CT recorder
# present" (the singular data source errors on missing, and there is no list
# data source), so prevention is pushed to the policy layer.
# ---------------------------------------------------------------------------

module "cis_rules" {
  count = var.skip_on_ct_managed_account ? 0 : 1

  source  = "cloudposse/config/aws//modules/cis-1-2-rules"
  version = "1.6.1"

  support_policy_arn     = var.support_policy_arn
  cloudtrail_bucket_name = var.cloudtrail_bucket_name

  context = module.this.context
}
