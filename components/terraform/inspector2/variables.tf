variable "region" {
  type        = string
  description = "AWS region."
}

variable "role" {
  type        = string
  description = "One of: management | delegated | member. Drives which resources apply."

  validation {
    condition     = contains(["management", "delegated", "member"], var.role)
    error_message = "role must be management, delegated, or member."
  }
}

variable "delegated_admin_account_id" {
  type        = string
  default     = null
  description = "Required when role=management. Account that becomes the Inspector2 delegated admin."
}

variable "auto_enable_ec2" {
  type    = bool
  default = true
}

variable "auto_enable_ecr" {
  type    = bool
  default = true
}

variable "auto_enable_lambda" {
  type    = bool
  default = true
}

variable "auto_enable_lambda_code" {
  type    = bool
  default = true
}

variable "enabler_account_ids" {
  type        = list(string)
  default     = []
  description = "Account IDs the enabler runs against (role=delegated). Typically the delegated-admin's own account and any hold-out members."
}

variable "enabler_resource_types" {
  type        = list(string)
  default     = ["EC2", "ECR", "LAMBDA", "LAMBDA_CODE"]
  description = "Resource types to scan."
}

variable "member_account_id" {
  type        = string
  default     = null
  description = "Required when role=member."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

