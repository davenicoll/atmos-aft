output "role" {
  description = "Echo of the role shape for this instance."
  value       = var.role
}

output "delegated_admin_account_id" {
  description = "Delegated-admin account (role=management only)."
  value       = try(aws_inspector2_delegated_admin_account.this[0].account_id, null)
}
