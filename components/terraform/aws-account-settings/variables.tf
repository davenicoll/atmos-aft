variable "region" {
  type        = string
  description = "AWS region."
}

variable "manage_password_policy" {
  type        = bool
  default     = true
  description = "Set false to skip password-policy management (e.g. shared identity accounts)."
}

variable "password_minimum_length" {
  type        = number
  default     = 14
  description = "Minimum IAM-user password length."
}

variable "password_max_age" {
  type        = number
  default     = 90
  description = "Days before password expiry."
}

variable "password_reuse_prevention" {
  type        = number
  default     = 24
  description = "Number of previous passwords that cannot be reused."
}

variable "manage_ebs_encryption" {
  type        = bool
  default     = true
  description = "Set EBS encryption-by-default."
}

variable "ebs_default_kms_key_id" {
  type        = string
  default     = null
  description = "Customer-managed KMS key ARN for default EBS encryption. Null = AWS-managed aws/ebs."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

