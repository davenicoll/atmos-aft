locals {
  enabled  = module.this.enabled
  name     = module.this.id
  dlq_name = "${module.this.id}-dlq"
}

resource "aws_sqs_queue" "dlq" {
  count = local.enabled ? 1 : 0

  name                              = local.dlq_name
  message_retention_seconds         = var.dlq_retention_seconds
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = 300

  tags = module.this.tags
}

resource "aws_sqs_queue" "main" {
  count = local.enabled ? 1 : 0

  name                              = local.name
  visibility_timeout_seconds        = var.visibility_timeout_seconds
  message_retention_seconds         = var.message_retention_seconds
  kms_master_key_id                 = var.kms_master_key_id
  kms_data_key_reuse_period_seconds = 300

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[0].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = module.this.tags
}
