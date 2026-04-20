module "scps" {
  source  = "cloudposse/service-control-policies/aws"
  version = "0.15.2"

  service_control_policy_statements   = var.statements
  service_control_policy_description  = var.description
  target_id                           = var.target_id

  context = module.this.context
}
