# Only wraps the CIS-1.2 submodule. NEVER use the top-level terraform-aws-config module
# in a CT-enrolled account — it always creates a configuration recorder that collides
# with the CT-provisioned recorder. See module-inventory §5.5.

module "cis_rules" {
  source  = "cloudposse/config/aws//modules/cis-1-2-rules"
  version = "1.6.1"

  support_policy_arn     = var.support_policy_arn
  cloudtrail_bucket_name = var.cloudtrail_bucket_name

  context = module.this.context
}
