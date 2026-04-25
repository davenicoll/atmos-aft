module "lambda" {
  for_each = var.functions
  source   = "cloudposse/lambda-function/aws"
  version  = "0.6.1"

  function_name = each.key
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

  inline_iam_policy = each.value.policy_json

  tracing_config_mode            = each.value.tracing_config_mode
  reserved_concurrent_executions = each.value.reserved_concurrent_executions

  context = module.this.context
}
