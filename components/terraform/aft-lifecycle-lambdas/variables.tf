variable "region" {
  type        = string
  description = "AWS region."
}

variable "functions" {
  type = map(object({
    filename              = string
    handler               = string
    runtime               = optional(string, "python3.12")
    timeout               = optional(number, 60)
    memory_size           = optional(number, 256)
    architecture          = optional(string, "arm64")
    environment           = optional(map(string), null)
    log_retention_in_days = optional(number, 90)
    log_kms_key_arn       = optional(string, null)
    policy_json           = optional(string, null)
  }))
  default     = {}
  description = "Map of logical function name → Lambda spec. Surviving AFT lifecycle Lambdas (delete_default_vpc, enable_cloudtrail, enroll_support). Path to zip must be resolvable at plan time."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

