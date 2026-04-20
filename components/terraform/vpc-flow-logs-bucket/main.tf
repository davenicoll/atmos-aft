module "flow_logs_bucket" {
  source  = "cloudposse/vpc-flow-logs-s3-bucket/aws"
  version = "1.3.1"

  force_destroy                      = false
  lifecycle_rule_enabled             = true
  noncurrent_version_expiration_days = var.expiration_days
  standard_transition_days           = var.standard_transition_days
  glacier_transition_days            = var.glacier_transition_days
  expiration_days                    = var.expiration_days

  context = module.this.context
}
