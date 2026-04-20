output "password_policy_managed" {
  description = "Whether this component manages the IAM account password policy."
  value       = var.manage_password_policy
}

output "ebs_encryption_managed" {
  description = "Whether this component manages EBS default encryption."
  value       = var.manage_ebs_encryption
}
