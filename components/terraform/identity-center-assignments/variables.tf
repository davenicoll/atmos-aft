variable "region" {
  type        = string
  description = "AWS region."
}

variable "account_assignments" {
  type        = any
  default     = []
  description = "List of assignment objects binding permission sets to principals + accounts (cloudposse/sso shape)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

