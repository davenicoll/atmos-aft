variable "region" {
  type        = string
  description = "AWS region."
}

variable "conformance_pack_url" {
  type        = string
  description = "URL to a Conformance Pack template (YAML/JSON). The submodule downloads the pack body from this URL."
}

variable "parameter_overrides" {
  type        = map(any)
  default     = {}
  description = "Map of parameter names to values to override from the conformance pack template."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

variable "skip_on_ct_managed_account" {
  type        = bool
  default     = true
  description = "When true, fail fast if a CT-managed configuration recorder (aws-controltower-BaselineConfigRecorder) is already present. The conformance-pack submodule attaches rules to the active recorder, but if CT owns the recorder those rules must be applied via the CT delegated admin path rather than inline. Default true guards against accidental in-account apply."
}
