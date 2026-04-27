variable "region" {
  type        = string
  description = "AWS region. One tfstate-backend instance per (account, region)."
}

variable "aft_mgmt_account_id" {
  type        = string
  description = "aft-mgmt account ID - hosts AtmosReadAllStateRole + AtmosCentralDeploymentRole. Grants read-only cross-account access to state."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aft_mgmt_account_id))
    error_message = "aft_mgmt_account_id must be a 12-digit AWS account ID."
  }
}

variable "bucket_name_override" {
  type        = string
  default     = null
  description = "Override the derived bucket name (default: atmos-tfstate-<account_id>-<region>). Only set for migration or legacy-named buckets."
}

variable "kms_alias_override" {
  type        = string
  default     = null
  description = "Override the default KMS alias (default: alias/atmos-tfstate)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

