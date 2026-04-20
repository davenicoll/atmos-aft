variable "region" {
  type        = string
  description = "AWS region."
}

variable "finding_publishing_frequency" {
  type        = string
  default     = "FIFTEEN_MINUTES"
  description = "Must match the delegated-admin setting unless there's a reason to diverge."
}

variable "s3_protection_enabled" {
  type    = bool
  default = true
}

variable "eks_protection_enabled" {
  type    = bool
  default = true
}

variable "malware_protection_enabled" {
  type    = bool
  default = true
}

variable "runtime_monitoring_enabled" {
  type    = bool
  default = true
}

variable "lambda_network_logs_enabled" {
  type    = bool
  default = true
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

