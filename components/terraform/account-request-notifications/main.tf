locals {
  topics = var.topics
}

module "sns_topic" {
  for_each = local.topics
  source   = "cloudposse/sns-topic/aws"
  version  = "1.2.0"

  attributes        = concat(module.this.attributes, [each.key])
  kms_master_key_id = var.kms_master_key_id
  subscribers       = each.value.subscribers
  sqs_dlq_enabled   = true

  context = module.this.context
}
