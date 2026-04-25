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

    # tracing_config_mode: PassThrough | Active | null. Real AFT runs Active
    # for end-to-end X-Ray; default null disables tracing (no extra IAM
    # permissions needed) so callers opt in deliberately.
    tracing_config_mode = optional(string, null)

    # reserved_concurrent_executions: -1 = unreserved (account-pool wide);
    # 0 = throttle to zero (effectively disable); positive = cap. Newly-
    # vended account hooks fan out wide, so capping per-function avoids
    # accidental account-pool exhaustion. Default -1 preserves prior behavior.
    reserved_concurrent_executions = optional(number, -1)
  }))
  default     = {}
  description = "Map of logical function name → Lambda spec. Surviving AFT lifecycle Lambdas (delete_default_vpc, enable_cloudtrail, enroll_support). Path to zip must be resolvable at plan time."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

