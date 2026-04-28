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
  description = "CMK ID used to encrypt state."
  value       = module.kms_key.key_id
}

output "kms_key_arn" {
  description = "CMK ARN used to encrypt state."
  value       = module.kms_key.key_arn
}

output "kms_alias_name" {
  description = "Human-readable alias for the CMK."
  value       = module.kms_key.alias_name
}
