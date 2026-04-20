output "bucket_id" {
  description = "Primary state bucket ID."
  value       = try(module.tfstate_backend.s3_bucket_id, null)
}

output "bucket_arn" {
  description = "Primary state bucket ARN."
  value       = try(module.tfstate_backend.s3_bucket_arn, null)
}

output "bucket_domain_name" {
  description = "Primary state bucket regional domain name."
  value       = try(module.tfstate_backend.s3_bucket_domain_name, null)
}

output "kms_key_id" {
  description = "CMK ID used to encrypt state (looked up from the alias we passed to the module)."
  value       = try(data.aws_kms_alias.tfstate[0].target_key_id, null)
}

output "kms_key_arn" {
  description = "CMK ARN used to encrypt state."
  value       = try(data.aws_kms_alias.tfstate[0].target_key_arn, null)
}

output "kms_alias_name" {
  description = "Human-readable alias for the CMK."
  value       = local.kms_alias
}
