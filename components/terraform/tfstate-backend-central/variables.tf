variable "region" {
  type        = string
  description = "AWS region for the bootstrap bucket (typically the same region as every other aft-mgmt component)."
}

variable "aft_mgmt_account_id" {
  type        = string
  description = "AFT management account ID. Used to template IAM role principals and the bucket name. Must be the account this component applies into."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aft_mgmt_account_id))
    error_message = "aft_mgmt_account_id must be a 12-digit AWS account ID."
  }
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

