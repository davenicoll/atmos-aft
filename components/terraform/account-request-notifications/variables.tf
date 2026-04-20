variable "region" {
  type        = string
  description = "AWS region."
}

variable "kms_master_key_id" {
  type        = string
  default     = null
  description = "Optional CMK alias/ARN for topic encryption. Null = AWS-owned key."
}

variable "topics" {
  type = map(object({
    subscribers = any
  }))
  default     = {}
  description = "Map of logical topic name → subscriber list. Example: {success = {subscribers = {...}}, failure = {...}}. Subscribers shape matches cloudposse/sns-topic's `subscribers` variable."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

