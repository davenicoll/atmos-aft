output "policy_id" {
  description = "SCP policy ID."
  value       = try(module.scps.id, null)
}

output "policy_arn" {
  description = "SCP policy ARN."
  value       = try(module.scps.arn, null)
}
