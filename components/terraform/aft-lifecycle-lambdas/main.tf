module "lambda" {
  for_each = var.functions
  source   = "cloudposse/lambda-function/aws"
  version  = "0.6.1"

  attributes    = concat(module.this.attributes, [each.key])
  filename      = each.value.filename
  handler       = each.value.handler
  runtime       = each.value.runtime
  timeout       = each.value.timeout
  memory_size   = each.value.memory_size
  architectures = [each.value.architecture]

  lambda_environment = each.value.environment == null ? null : {
    variables = each.value.environment
  }

  cloudwatch_logs_retention_in_days = each.value.log_retention_in_days
  cloudwatch_logs_kms_key_arn       = each.value.log_kms_key_arn

  policy_json = each.value.policy_json

  context = module.this.context
}
