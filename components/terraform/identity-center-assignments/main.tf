module "assignments" {
  source  = "cloudposse/sso/aws//modules/account-assignments"
  version = "1.2.0"

  account_assignments = var.account_assignments
}
