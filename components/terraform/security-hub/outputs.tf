output "enabled_standards" {
  description = "Subscribed standards ARNs."
  value       = var.enabled_standards
}

output "delegated_admin_account_id" {
  description = "Registered delegated-admin account ID (null in non-mgmt stacks)."
  value       = try(aws_securityhub_organization_admin_account.this[0].admin_account_id, null)
}
