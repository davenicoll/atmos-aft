module "parameters" {
  source  = "cloudposse/ssm-parameter-store/aws"
  version = "0.13.0"

  kms_arn    = var.kms_arn
  parameters = var.parameters

  context = module.this.context
}
