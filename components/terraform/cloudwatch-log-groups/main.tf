module "log_group" {
  for_each = var.log_groups
  source   = "cloudposse/cloudwatch-logs/aws"
  version  = "0.6.9"

  attributes        = concat(module.this.attributes, [each.key])
  retention_in_days = each.value.retention_in_days
  kms_key_arn       = each.value.kms_key_arn

  context = module.this.context
}
