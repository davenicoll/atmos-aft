output "event_rule_arn" {
  description = "ARN of the EventBridge rule that matches all CT lifecycle events (CreateManagedAccount, UpdateManagedAccount, RegisterOrganizationalUnit). The target embeds the full event as client_payload; the consumer workflow branches on detail.eventName."
  value       = try(aws_cloudwatch_event_rule.ct_lifecycle[0].arn, null)
}

output "api_destination_arn" {
  description = "ARN of the GitHub dispatch API destination."
  value       = try(aws_cloudwatch_event_api_destination.github_dispatch[0].arn, null)
}

output "connection_arn" {
  description = "ARN of the EventBridge connection carrying the GitHub auth token."
  value       = try(aws_cloudwatch_event_connection.github[0].arn, null)
}

output "dlq_arn" {
  description = "SQS DLQ ARN for undelivered dispatches."
  value       = try(aws_sqs_queue.dlq[0].arn, null)
}

output "dlq_url" {
  description = "SQS DLQ URL (for replay tooling)."
  value       = try(aws_sqs_queue.dlq[0].url, null)
}

output "alarm_topic_arn" {
  description = "SNS topic ARN carrying DLQ/rotator alarms."
  value       = try(aws_sns_topic.alarms[0].arn, null)
}

output "rotator_function_arn" {
  description = "Rotator Lambda ARN. Null in PAT mode."
  value       = try(aws_lambda_function.rotator[0].arn, null)
}

output "github_auth_mode" {
  description = "Echo of the selected auth mode."
  value       = var.github_auth_mode
}
