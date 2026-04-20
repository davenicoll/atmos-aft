# NEVER target the CT-managed aws-controltower/CloudTrailLogs bucket.
# This is an ADDITIONAL log lake (application logs, CloudTrail data events).

module "logging_bucket" {
  source  = "cloudposse/s3-bucket/aws"
  version = "4.12.0"

  acl                           = "private"
  versioning_enabled            = true
  sse_algorithm                 = var.sse_algorithm
  kms_master_key_arn            = var.kms_master_key_arn == null ? "" : var.kms_master_key_arn
  force_destroy                 = false
  allow_ssl_requests_only       = true
  lifecycle_configuration_rules = var.lifecycle_rules
  block_public_acls             = true
  block_public_policy           = true
  ignore_public_acls            = true
  restrict_public_buckets       = true

  logging = var.access_log_bucket_name == null ? [] : [{
    bucket_name = var.access_log_bucket_name
    prefix      = var.access_log_prefix
  }]

  context = module.this.context
}
