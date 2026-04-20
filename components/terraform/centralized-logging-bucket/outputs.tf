output "bucket_id" {
  description = "Bucket ID."
  value       = try(module.logging_bucket.bucket_id, null)
}

output "bucket_arn" {
  description = "Bucket ARN."
  value       = try(module.logging_bucket.bucket_arn, null)
}

output "bucket_domain_name" {
  description = "Bucket regional domain name."
  value       = try(module.logging_bucket.bucket_domain_name, null)
}
