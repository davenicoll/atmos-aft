variable "region" {
  type        = string
  description = "AWS region."
}

variable "multi_region" {
  type        = bool
  default     = false
  description = "Multi-region trail. Only set true when this trail does NOT overlap with the CT-managed org trail."
}

variable "include_global_service_events" {
  type        = bool
  default     = false
  description = "Include IAM and STS events. False by default — the CT org trail already does this."
}

variable "kms_key_arn" {
  type        = string
  default     = null
  description = "CMK for log-file encryption. Null = AWS-managed."
}

variable "event_selectors" {
  type        = any
  default     = []
  description = "Event selectors (e.g. S3 data events, Lambda data events). Passed through to cloudposse/cloudtrail shape."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

