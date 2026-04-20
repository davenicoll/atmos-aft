# SQS DLQ + SNS alarms for the EventBridge API destination.
# 14-day retention covers a Fri-evening-to-Mon-morning rotator outage per gha-design.md §5.12.

resource "aws_sqs_queue" "dlq" {
  count = local.enabled ? 1 : 0

  name                       = "${module.this.id}-ct-dispatch-dlq"
  message_retention_seconds  = 1209600  # 14 days
  visibility_timeout_seconds = 900
  sqs_managed_sse_enabled    = true

  tags = module.this.tags
}

# EventBridge role needs SendMessage on the DLQ only. Keep surface narrow.
resource "aws_sqs_queue_policy" "dlq" {
  count = local.enabled ? 1 : 0

  queue_url = aws_sqs_queue.dlq[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridgeSendMessage"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dlq[0].arn
      Condition = {
        ArnEquals = {
          "aws:SourceArn" = aws_cloudwatch_event_rule.ct_lifecycle[0].arn
        }
      }
    }]
  })
}

resource "aws_sns_topic" "alarms" {
  count = local.enabled ? 1 : 0

  name              = "${module.this.id}-ct-dispatch-alarms"
  kms_master_key_id = "alias/aws/sns"

  tags = module.this.tags
}

resource "aws_sns_topic_subscription" "alarms" {
  for_each = local.enabled && length(var.alarm_notification_emails) > 0 ? toset(var.alarm_notification_emails) : toset([])

  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  count = local.enabled ? 1 : 0

  alarm_name          = "${module.this.id}-ct-dispatch-dlq-not-empty"
  alarm_description   = "CT-dispatch DLQ has messages. Investigate: GitHub dispatch endpoint unavailable? Connection secret expired? Rate-limited?"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = { QueueName = aws_sqs_queue.dlq[0].name }

  alarm_actions = [aws_sns_topic.alarms[0].arn]

  tags = module.this.tags
}
