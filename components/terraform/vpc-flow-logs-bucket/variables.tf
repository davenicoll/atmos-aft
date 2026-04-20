variable "region" {
  type        = string
  description = "AWS region (one bucket per region in the security/audit account)."
}

variable "standard_transition_days" {
  type    = number
  default = 30
}

variable "glacier_transition_days" {
  type    = number
  default = 90
}

variable "expiration_days" {
  type    = number
  default = 365
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

