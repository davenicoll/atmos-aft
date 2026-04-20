output "bucket_id" {
  description = "Name of the central bootstrap state bucket in aft-mgmt."
  value       = module.tfstate_backend.s3_bucket_id
}

output "bucket_arn" {
  description = "ARN of the central bootstrap state bucket."
  value       = module.tfstate_backend.s3_bucket_arn
}

output "kms_key_id" {
  description = "KMS key ID protecting the bootstrap bucket."
  value       = try(data.aws_kms_alias.tfstate[0].target_key_id, null)
}

output "kms_key_arn" {
  description = "KMS key ARN protecting the bootstrap bucket."
  value       = try(data.aws_kms_alias.tfstate[0].target_key_arn, null)
}

output "kms_alias_name" {
  description = "KMS alias (alias/atmos-tfstate-bootstrap)."
  value       = "alias/atmos-tfstate-bootstrap"
}
