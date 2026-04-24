variable "region" {
  type        = string
  description = "AWS region."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

variable "support_policy_arn" {
  type        = string
  description = "ARN of the IAM policy granting access to AWS Support, required for CIS 1.20 compliance (support role for managing incidents with AWS Support)."
}

variable "cloudtrail_bucket_name" {
  type        = string
  description = "Name of the S3 bucket where CloudTrail logs are sent, required for CIS 2.6 compliance (S3 bucket access logging on the CloudTrail bucket)."
}

variable "skip_on_ct_managed_account" {
  type        = bool
  default     = true
  description = "When true, fail fast if a CT-managed configuration recorder (aws-controltower-BaselineConfigRecorder) is already present in this account. The CIS-1.2 submodule declares its own aws_config_configuration_recorder, which cannot coexist with CT's recorder - apply would collide on re-provision. Set to false only if you have manually removed the CT recorder and understand the implications."
}
