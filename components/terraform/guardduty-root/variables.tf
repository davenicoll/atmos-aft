variable "region" {
  type        = string
  description = "AWS region."
}

variable "delegated_admin_account_id" {
  type        = string
  description = "Account ID to register as the GuardDuty delegated admin (typically the audit/security account)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

