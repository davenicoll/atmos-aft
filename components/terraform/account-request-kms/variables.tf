variable "region" {
  type        = string
  description = "AWS region. One instance per region per purpose."
}

variable "description" {
  type        = string
  default     = "Atmos-AFT management-plane CMK"
  description = "Human-readable CMK description."
}

variable "alias" {
  type        = string
  description = "KMS alias name (must start with 'alias/')."

  validation {
    condition     = can(regex("^alias/", var.alias))
    error_message = "alias must start with 'alias/'."
  }
}

variable "deletion_window_in_days" {
  type        = number
  default     = 30
  description = "Waiting period before key is permanently deleted."
}

variable "policy" {
  type        = string
  default     = null
  description = "Optional full key policy JSON. Omit to use the module's default (account root grant)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

