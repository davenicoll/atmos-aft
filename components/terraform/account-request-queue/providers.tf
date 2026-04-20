# The `aws` provider assumes the target-account role when var.target_role_arn
# is set, otherwise it runs under the caller's creds (the central role
# surfaced by the configure-aws composite action). See docs/architecture/
# gha-design.md §4.5 for the full chain and task #26 for the rationale.

provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.target_role_arn != "" ? [1] : []
    content {
      role_arn     = var.target_role_arn
      session_name = "atmos-aft"
    }
  }
}

