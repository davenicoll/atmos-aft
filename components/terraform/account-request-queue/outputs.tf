output "queue_arn" {
  description = "Main queue ARN."
  value       = try(aws_sqs_queue.main[0].arn, null)
}

output "queue_url" {
  description = "Main queue URL."
  value       = try(aws_sqs_queue.main[0].id, null)
}

output "dlq_arn" {
  description = "DLQ ARN."
  value       = try(aws_sqs_queue.dlq[0].arn, null)
}

output "dlq_url" {
  description = "DLQ URL."
  value       = try(aws_sqs_queue.dlq[0].id, null)
}
