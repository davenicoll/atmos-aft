module "parameters" {
  source  = "cloudposse/ssm-parameter-store/aws"
  version = "0.13.0"

  kms_arn = var.kms_arn != null ? var.kms_arn : ""
  parameter_write = [
    for k, v in var.parameters : {
      name        = k
      value       = v.value
      type        = v.type
      tier        = v.tier
      description = v.description
      overwrite   = v.overwrite
    }
  ]

  context = module.this.context
}
