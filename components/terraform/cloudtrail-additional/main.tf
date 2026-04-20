# Per-account supplementary CloudTrail trail (e.g. for data events).
# NEVER replace or override the org trail that Control Tower manages.

module "trail_bucket" {
  source  = "cloudposse/cloudtrail-s3-bucket/aws"
  version = "1.2.0"

  force_destroy = false

  context = module.this.context
}

module "trail" {
  source  = "cloudposse/cloudtrail/aws"
  version = "0.24.0"

  s3_bucket_name                = module.trail_bucket.bucket_id
  enable_log_file_validation    = true
  enable_logging                = true
  include_global_service_events = var.include_global_service_events
  is_multi_region_trail         = var.multi_region
  kms_key_arn                   = var.kms_key_arn
  event_selector                = var.event_selectors

  context = module.this.context
}
