variable "region" {
  type        = string
  description = "AWS region."
}

variable "lifecycle_configuration_rules" {
  type        = any
  default     = []
  description = "S3 lifecycle rules (module shape). Leave empty to use defaults below."
}

variable "standard_transition_days" {
  type        = number
  default     = 30
  description = "Days before objects move to STANDARD_IA."
}

variable "glacier_transition_days" {
  type        = number
  default     = 90
  description = "Days before objects move to GLACIER."
}

variable "expiration_days" {
  type        = number
  default     = 365
  description = "Days before access-log objects expire."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

