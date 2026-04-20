module "permission_sets" {
  source  = "cloudposse/sso/aws"
  version = "1.2.0"

  permission_sets = var.permission_sets

  # No assignments here — see identity-center-assignments.
  account_assignments = []

  context = module.this.context
}
