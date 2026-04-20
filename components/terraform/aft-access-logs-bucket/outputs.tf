output "bucket_id" {
  description = "Access-logs bucket ID."
  value       = try(module.access_logs.bucket_id, null)
}

output "bucket_arn" {
  description = "Access-logs bucket ARN."
  value       = try(module.access_logs.bucket_arn, null)
}

output "bucket_domain_name" {
  description = "Access-logs bucket domain name."
  value       = try(module.access_logs.bucket_domain_name, null)
}
