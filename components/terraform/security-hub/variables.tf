variable "region" {
  type        = string
  description = "AWS region."
}

variable "enabled_standards" {
  type        = list(string)
  default     = []
  description = "Standards ARNs to subscribe (e.g. CIS, PCI-DSS, AWS Foundational)."
}

variable "finding_aggregator_enabled" {
  type        = bool
  default     = false
  description = "Only true in the delegated-admin stack. One aggregator per org."
}

variable "finding_aggregator_linking_mode" {
  type        = string
  default     = "ALL_REGIONS"
  description = "ALL_REGIONS | ALL_REGIONS_EXCEPT_SPECIFIED | SPECIFIED_REGIONS."
}

variable "finding_aggregator_regions" {
  type        = list(string)
  default     = []
  description = "Regions to include/exclude based on linking_mode."
}

variable "set_delegated_admin_account_id" {
  type        = string
  default     = null
  description = "If non-null, registers the given account as Security Hub delegated admin (only set from org management stack)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

