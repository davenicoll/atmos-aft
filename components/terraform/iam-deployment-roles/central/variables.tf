variable "region" {
  type        = string
  description = "AWS region. IAM is global but the provider needs one."
}

variable "github_org" {
  type        = string
  description = "GitHub organization name (for OIDC `sub` claim pinning)."
}

variable "github_repo" {
  type        = string
  description = "GitHub repository name hosting this config."
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "ARN of the GitHub OIDC provider in this account. Created by the `github-oidc-provider` component in bootstrap step 3. Example: arn:aws:iam::<aft-mgmt>:oidc-provider/token.actions.githubusercontent.com"

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must be a GitHub OIDC provider ARN in this account."
  }
}

variable "max_session_duration" {
  type        = number
  default     = 3600
  description = "Max session duration in seconds. Default 1 hour; raise to up to 43200 for long provisioning runs."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

