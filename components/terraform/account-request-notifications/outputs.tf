output "topic_arns" {
  description = "Map of logical name → topic ARN."
  value       = { for k, m in module.sns_topic : k => m.sns_topic_arn }
}

output "topic_names" {
  description = "Map of logical name → topic name."
  value       = { for k, m in module.sns_topic : k => m.sns_topic_name }
}

output "dlq_urls" {
  description = "Map of logical name → DLQ URL."
  value       = { for k, m in module.sns_topic : k => try(m.sqs_dlq_url, null) }
}
