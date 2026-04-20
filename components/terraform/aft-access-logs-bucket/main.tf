module "access_logs" {
  source  = "cloudposse/s3-log-storage/aws"
  version = "2.0.0"

  lifecycle_configuration_rules = var.lifecycle_configuration_rules
  standard_transition_days      = var.standard_transition_days
  glacier_transition_days       = var.glacier_transition_days
  expiration_days               = var.expiration_days
  force_destroy                 = false
  sse_algorithm                 = "AES256"
  access_log_bucket_name        = ""
  block_public_acls             = true
  block_public_policy           = true
  ignore_public_acls            = true
  restrict_public_buckets       = true

  context = module.this.context
}
