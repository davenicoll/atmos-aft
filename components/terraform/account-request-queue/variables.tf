variable "region" {
  type        = string
  description = "AWS region."
}

variable "visibility_timeout_seconds" {
  type        = number
  default     = 300
  description = "Main-queue visibility timeout. Match the Lambda/consumer timeout."
}

variable "message_retention_seconds" {
  type        = number
  default     = 1209600
  description = "Main-queue retention (default 14 days)."
}

variable "dlq_retention_seconds" {
  type        = number
  default     = 1209600
  description = "DLQ retention (default 14 days)."
}

variable "max_receive_count" {
  type        = number
  default     = 3
  description = "Redrive threshold before moving to DLQ."
}

variable "kms_master_key_id" {
  type        = string
  default     = "alias/aws/sqs"
  description = "KMS alias/key ID for SSE. Pass a customer CMK for non-default encryption."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

