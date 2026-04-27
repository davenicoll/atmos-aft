module "flow_logs_bucket" {
  source  = "cloudposse/vpc-flow-logs-s3-bucket/aws"
  version = "1.3.1"

  # This component owns the central log-archive BUCKET only - it does not
  # provision aws_flow_log itself (those are created per-VPC in vended
  # accounts and write to this bucket cross-account). The upstream module
  # defaults `flow_log_enabled = true` and `vpc_id = null`, which trips
  # AWS provider plan-time `ExactlyOneOf` validation. Pin off here.
  flow_log_enabled = false

  force_destroy                      = false
  lifecycle_rule_enabled             = true
  noncurrent_version_expiration_days = var.expiration_days
  standard_transition_days           = var.standard_transition_days
  glacier_transition_days            = var.glacier_transition_days
  expiration_days                    = var.expiration_days

  context = module.this.context
}
