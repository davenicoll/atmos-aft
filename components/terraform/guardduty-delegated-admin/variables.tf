variable "region" {
  type        = string
  description = "AWS region."
}

variable "finding_publishing_frequency" {
  type        = string
  default     = "FIFTEEN_MINUTES"
  description = "How often findings publish to EventBridge. One of SIX_HOURS, ONE_HOUR, FIFTEEN_MINUTES."
}

variable "auto_enable_organization_members" {
  type        = string
  default     = "ALL"
  description = "Which accounts new-member auto-enable applies to. ALL | NEW | NONE."
}

variable "s3_protection_enabled" {
  type        = bool
  default     = true
  description = "Enable S3 data-event monitoring."
}

variable "eks_protection_enabled" {
  type        = bool
  default     = true
  description = "Enable EKS audit-log + runtime monitoring."
}

variable "malware_protection_enabled" {
  type        = bool
  default     = true
  description = "Enable malware scan for EBS volumes."
}

variable "runtime_monitoring_enabled" {
  type        = bool
  default     = true
  description = "Enable runtime monitoring (agent-based)."
}

variable "lambda_network_logs_enabled" {
  type        = bool
  default     = true
  description = "Enable Lambda network-activity monitoring."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

