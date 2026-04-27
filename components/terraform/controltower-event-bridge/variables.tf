variable "region" {
  type        = string
  description = "AWS region. Component lives in the CT management account."
}

variable "github_org" {
  type        = string
  description = "GitHub organization hosting the atmos-aft repo."
}

variable "github_repo" {
  type        = string
  description = "GitHub repo name receiving repository_dispatch events."
}

variable "github_auth_mode" {
  type        = string
  default     = "app"
  description = "Authentication mode for the GitHub dispatch call. 'app' (default) = GitHub App with rotator Lambda; 'pat' = fine-grained PAT with manual rotation."

  validation {
    condition     = contains(["app", "pat"], var.github_auth_mode)
    error_message = "github_auth_mode must be 'app' or 'pat'."
  }
}

variable "github_app_id" {
  type        = string
  default     = ""
  description = "GitHub App numeric ID. Required when github_auth_mode='app'. Stored unencrypted - this is the public App identifier, not the private key."
}

variable "github_app_installation_id" {
  type        = string
  default     = ""
  description = "GitHub App installation ID on the target repo. Required when github_auth_mode='app'."
}

variable "rotator_zip_path" {
  type        = string
  default     = ""
  description = "Path to the rotator Lambda zip artifact. Required when github_auth_mode='app'. Built and uploaded by the GHA pipeline; stored as a repo artifact or local checkout path."
}

variable "alarm_notification_emails" {
  type        = list(string)
  default     = []
  description = "Email addresses subscribed to the CT-dispatch alarm SNS topic. Covers DLQ-not-empty, rotator errors, rotator staleness."
}

variable "target_role_arn" {
  type        = string
  default     = ""
  description = "ARN of the role Terraform should assume in the target account before acting. Set via TF_VAR_target_role_arn by the configure-aws GHA composite action. Empty = run under the caller's creds (used for components that live in AFT-mgmt / the central account)."
}

