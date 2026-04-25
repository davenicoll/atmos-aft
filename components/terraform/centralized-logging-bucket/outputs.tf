output "bucket_id" {
  description = "Bucket ID."
  value       = try(module.logging_bucket.bucket_id, null)

  # Cross-variable guard: aws:kms + null kms_master_key_arn silently falls
  # back to the AWS-managed `aws/s3` key, defeating the point of choosing
  # aws:kms. Variable validation can't cross-reference; an output
  # precondition fires loudly at plan time.
  precondition {
    condition     = var.sse_algorithm != "aws:kms" || var.kms_master_key_arn != null
    error_message = "When sse_algorithm=aws:kms, kms_master_key_arn must be a non-null CMK ARN. Without an explicit CMK the s3-bucket module silently uses the AWS-managed aws/s3 key. Either set sse_algorithm=AES256 or pass a CMK ARN."
  }
}

output "bucket_arn" {
  description = "Bucket ARN."
  value       = try(module.logging_bucket.bucket_arn, null)
}

output "bucket_domain_name" {
  description = "Bucket regional domain name."
  value       = try(module.logging_bucket.bucket_domain_name, null)
}
