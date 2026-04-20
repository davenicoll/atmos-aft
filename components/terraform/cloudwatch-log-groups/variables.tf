variable "region" {
  type        = string
  description = "AWS region."
}

variable "log_groups" {
  type = map(object({
    retention_in_days = optional(number, 90)
    kms_key_arn       = optional(string, null)
  }))
  default     = {}
  description = "Map of logical name → log-group spec. Name is suffixed to module.this.id."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

