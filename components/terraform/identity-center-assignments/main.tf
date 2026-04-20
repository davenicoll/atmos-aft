module "assignments" {
  source  = "cloudposse/sso/aws"
  version = "1.2.0"

  # Permission-set definitions are owned by identity-center-permission-sets; skip here.
  permission_sets     = []
  account_assignments = var.account_assignments

  context = module.this.context
}
