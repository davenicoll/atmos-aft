variable "region" {
  type        = string
  description = "AWS region."
}

variable "conformance_pack" {
  type = object({
    name            = string
    template_body   = string
    input_parameter = optional(map(string), {})
  })
  description = "Conformance-pack definition. template_body is the YAML/JSON pack body; input_parameter is a flat map of pack-parameter overrides."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

