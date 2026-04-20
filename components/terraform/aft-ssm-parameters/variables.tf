variable "region" {
  type        = string
  description = "AWS region."
}

variable "kms_arn" {
  type        = string
  default     = null
  description = "Optional CMK ARN for SecureString parameters."
}

variable "parameters" {
  type = map(object({
    value       = string
    type        = optional(string, "String")
    tier        = optional(string, "Standard")
    description = optional(string, "")
    overwrite   = optional(bool, true)
  }))
  default     = {}
  description = "Map of SSM parameter name → spec. Keys become the parameter path. Merged across stack layers via list_merge_strategy=merge."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

