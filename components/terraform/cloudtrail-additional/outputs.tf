output "trail_arn" {
  description = "Trail ARN."
  value       = try(module.trail.cloudtrail_arn, null)
}

output "trail_bucket_id" {
  description = "Trail log bucket ID."
  value       = try(module.trail_bucket.bucket_id, null)
}

output "trail_bucket_arn" {
  description = "Trail log bucket ARN."
  value       = try(module.trail_bucket.bucket_arn, null)
}
