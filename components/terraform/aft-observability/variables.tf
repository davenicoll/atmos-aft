variable "region" {
  type        = string
  description = "AWS region."
}

variable "queries" {
  type = map(object({
    log_group_names = list(string)
    query_string    = string
  }))
  default     = {}
  description = "Map of logical name → saved CloudWatch Logs Insights query. Consolidates `account_id_query`, `customization_request_query`, etc."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

