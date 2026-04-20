output "bucket_id" {
  description = "Flow-logs bucket ID."
  value       = try(module.flow_logs_bucket.bucket_id, null)
}

output "bucket_arn" {
  description = "Flow-logs bucket ARN."
  value       = try(module.flow_logs_bucket.bucket_arn, null)
}
