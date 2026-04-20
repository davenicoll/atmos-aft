variable "region" {
  type        = string
  description = "AWS region."
}

variable "parent_zone_name" {
  type        = string
  description = "FQDN of the parent zone (dns-primary output)."
}

variable "parent_zone_id" {
  type        = string
  default     = null
  description = "Parent zone ID. Set only when the same provider can write to the parent zone. Cross-account: leave null and create the delegation externally."
}

variable "subzone_label" {
  type        = string
  description = "Single label appended to the parent zone (e.g. 'prod' → prod.example.com)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

