variable "region" {
  type        = string
  description = "AWS region for the event data store. Typically the audit account's primary region."
}

variable "retention_days" {
  type        = number
  default     = 2557
  description = "Retention in days. Default 2557 (≈7 years)."

  validation {
    condition     = var.retention_days >= 7 && var.retention_days <= 3653
    error_message = "CloudTrail Lake retention must be between 7 and 3653 days."
  }
}

variable "multi_region_enabled" {
  type        = bool
  default     = false
  description = "Single-region store by default. Flip on only if DR requires cross-region capture."
}

variable "kms_key_id" {
  type        = string
  default     = null
  description = "Optional customer-managed KMS key ARN for event data store encryption. Null uses the AWS-managed CloudTrail key."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

