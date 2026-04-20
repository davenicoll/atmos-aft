module "permission_sets" {
  source  = "cloudposse/sso/aws//modules/permission-sets"
  version = "1.2.0"

  permission_sets = var.permission_sets
}
