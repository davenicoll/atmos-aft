variable "region" {
  type        = string
  description = "AWS region. IAM is global but the target provider needs one."
}

variable "aft_mgmt_account_id" {
  type        = string
  description = "Account ID hosting AtmosCentralDeploymentRole and AtmosPlanOnlyRole."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aft_mgmt_account_id))
    error_message = "aft_mgmt_account_id must be a 12-digit AWS account ID."
  }
}

variable "account_class" {
  type        = string
  description = "Class of the target account. One of: ct-mgmt, aft-mgmt, audit, log-archive, vended. Controls whether sts:ExternalId is required in the trust policy (required for the four CT-core classes; omitted for vended)."

  validation {
    condition     = contains(["ct-mgmt", "aft-mgmt", "audit", "log-archive", "vended"], var.account_class)
    error_message = "account_class must be one of: ct-mgmt, aft-mgmt, audit, log-archive, vended."
  }
}

variable "atmos_external_id" {
  type        = string
  default     = ""
  description = "Static per-org UUID used as sts:ExternalId guardrail on the four CT-core placements. Stored in GHA vars as ATMOS_EXTERNAL_ID. Ignored when account_class=vended."
  sensitive   = true

  validation {
    condition     = var.atmos_external_id == "" || can(regex("^[a-zA-Z0-9_-]{16,128}$", var.atmos_external_id))
    error_message = "atmos_external_id must be 16-128 chars of [a-zA-Z0-9_-] or empty (for vended accounts)."
  }
}

variable "max_session_duration" {
  type        = number
  default     = 3600
  description = "Max session duration in seconds."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the bootstrap role (OrganizationAccountAccessRole or AWSControlTowerExecution) used to stamp AtmosDeploymentRole + ReadOnly into the target account. Set via TF_VAR_target_role_arn from the configure-aws composite action. Must be non-empty when this component runs."
}
