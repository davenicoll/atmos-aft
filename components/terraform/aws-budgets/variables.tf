variable "region" {
  type        = string
  description = "AWS region."
}

variable "budgets" {
  type        = any
  default     = []
  description = "List of budget objects passed straight through to cloudposse/budgets/aws. Each entry needs name, budget_type, limit_amount, time_unit, and (optionally) notifications."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

