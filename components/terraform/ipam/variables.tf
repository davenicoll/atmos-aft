variable "region" {
  type        = string
  description = "IPAM home region."
}

variable "description" {
  type    = string
  default = "Org-wide IP address manager."
}

variable "operating_regions" {
  type        = list(string)
  description = "Regions where IPAM allocates (must include region)."
}

variable "top_pool_cidr" {
  type        = string
  description = "Top-level CIDR provisioned into the root pool (e.g. 10.0.0.0/8)."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

