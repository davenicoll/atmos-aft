variable "region" {
  type        = string
  description = "AWS region (the CT management account's home region)."
}

variable "account_name" {
  type        = string
  description = "Human-readable account name. Becomes the Organizations account alias and part of the provisioned-product name."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,48}[a-z0-9]$", var.account_name))
    error_message = "account_name must be 3-50 chars, lowercase alphanumeric with hyphens."
  }
}

variable "account_email" {
  type        = string
  description = "Root email for the new account. Must be globally unique across AWS."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.account_email))
    error_message = "account_email must be a valid email address."
  }
}

variable "managed_organizational_unit" {
  type        = string
  description = "Name of the CT-registered OU where this account lands."
}

variable "sso_user_email" {
  type        = string
  description = "Email for the initial SSO user created by CT for this account."
}

variable "sso_user_first_name" {
  type        = string
  description = "First name for the initial SSO user."
}

variable "sso_user_last_name" {
  type        = string
  description = "Last name for the initial SSO user."
}

variable "ct_product_id" {
  type        = string
  description = "Service Catalog product ID of 'AWS Control Tower Account Factory'. Stable per org; cache in SSM as /atmos/ct/product-id."
}

variable "provisioning_artifact_name" {
  type        = string
  default     = "AWS Control Tower Account Factory"
  description = "Provisioning artifact name. Defaults to the CT-managed artifact; override if pinning to a specific version."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

