variable "region" {
  type        = string
  description = "AWS region (attach runs in mgmt account regardless - this is the provider region)."
}

variable "statements" {
  type        = any
  description = "SCP statements (Cloudposse shape - map of statement-id → {effect, actions, resources, conditions})."
}

variable "description" {
  type        = string
  default     = "Atmos-AFT additional SCP - never CT guardrails."
  description = "Policy description."
}

variable "target_id" {
  type        = string
  description = "OU ID or Account ID to attach the SCP to. Never attach to roots CT owns."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

