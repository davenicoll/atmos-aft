output "event_data_store_arn" {
  description = "ARN of the CloudTrail Lake event data store. Referenced by drift-detection workflow queries and downstream audit components."
  value       = try(aws_cloudtrail_event_data_store.this[0].arn, null)
}

output "event_data_store_id" {
  description = "ID of the event data store (last path segment of the ARN)."
  value       = try(aws_cloudtrail_event_data_store.this[0].id, null)
}

output "event_data_store_name" {
  description = "Name of the event data store."
  value       = try(aws_cloudtrail_event_data_store.this[0].name, null)
}
