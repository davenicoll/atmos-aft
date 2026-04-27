# Per-account supplementary CloudTrail trail (e.g. for data events).
# NEVER replace or override the org trail that Control Tower manages.

module "trail_bucket" {
  source  = "cloudposse/cloudtrail-s3-bucket/aws"
  version = "0.32.0"

  force_destroy = false

  # Server-access logging on the trail bucket - required by CIS 2.6.
  # Set var.access_log_bucket_name to point at the centralized logging
  # bucket (or leave empty in dev to skip).
  access_log_bucket_name = var.access_log_bucket_name

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
