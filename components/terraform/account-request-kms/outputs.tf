output "key_id" {
  description = "CMK ID."
  value       = try(module.kms_key.key_id, null)
}

output "key_arn" {
  description = "CMK ARN."
  value       = try(module.kms_key.key_arn, null)
}

output "alias_name" {
  description = "Alias name."
  value       = try(module.kms_key.alias_name, null)
}

output "alias_arn" {
  description = "Alias ARN."
  value       = try(module.kms_key.alias_arn, null)
}
