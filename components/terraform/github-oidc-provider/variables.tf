variable "region" {
  type        = string
  description = "AWS region."
}

variable "github_oidc_host" {
  type        = string
  default     = "token.actions.githubusercontent.com"
  description = "GitHub's OIDC issuer host (no scheme)."
}

variable "client_id_list" {
  type        = list(string)
  default     = ["sts.amazonaws.com"]
  description = "Audience (client_id) list for the provider."
}

variable "thumbprint_list" {
  type        = list(string)
  description = "GitHub OIDC TLS cert thumbprints. AWS ignores these post-2023 for token.actions.githubusercontent.com but the CreateOpenIDConnectProvider API still requires a non-empty list. Defaults to the two well-known GitHub Actions OIDC thumbprints."
  default = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

