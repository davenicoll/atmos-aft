variable "region" {
  type        = string
  description = "AWS region."
}

variable "sse_algorithm" {
  type        = string
  default     = "aws:kms"
  description = "SSE algorithm. AES256 or aws:kms (CMK required when aws:kms — see kms_master_key_arn validation)."

  validation {
    condition     = contains(["AES256", "aws:kms"], var.sse_algorithm)
    error_message = "sse_algorithm must be one of: AES256, aws:kms."
  }
}

variable "kms_master_key_arn" {
  type        = string
  default     = null
  description = "KMS key ARN for SSE-KMS. Required (non-null) when sse_algorithm=aws:kms — without it the s3-bucket module silently falls back to the AWS-managed aws/s3 key."
}

variable "lifecycle_rules" {
  type        = any
  default     = []
  description = "Lifecycle rules (s3-bucket module shape). Typical shape: transition to IA @ 30d, Glacier @ 90d, expiration @ 2555d for 7y retention."
}

variable "access_log_bucket_name" {
  type        = string
  default     = null
  description = "Access-logs target bucket name. Null disables access logging."
}

variable "access_log_prefix" {
  type        = string
  default     = "logs/"
  description = "Prefix inside access_log_bucket_name."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

