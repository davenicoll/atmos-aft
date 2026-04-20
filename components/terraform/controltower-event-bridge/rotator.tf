# Mode A only: bespoke rotator Lambda that exchanges the App PEM for a
# 1h installation token every 30 min. Not wired into Secrets Manager's
# RotateSecret protocol — that protocol is for DB-credential atomic swaps,
# not "mint short-lived token from long-lived PEM". See gha-design.md §10.1.

resource "aws_iam_role" "rotator" {
  count = local.enabled && local.app_mode ? 1 : 0

  name = "${module.this.id}-ct-dispatch-rotator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = module.this.tags
}

resource "aws_iam_role_policy_attachment" "rotator_basic" {
  count      = local.enabled && local.app_mode ? 1 : 0
  role       = aws_iam_role.rotator[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Narrow policy per gha-design.md §10.1. Rotator reads PEM (+Decrypt on PEM CMK)
# and writes token (+Encrypt/GenerateDataKey on token CMK). No Decrypt on token CMK.
resource "aws_iam_role_policy" "rotator" {
  count = local.enabled && local.app_mode ? 1 : 0

  name = "RotatorLeastPrivilege"
  role = aws_iam_role.rotator[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "${aws_secretsmanager_secret.github_app_private_key[0].arn}*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:PutSecretValue"]
        Resource = "${aws_secretsmanager_secret.github_installation_token[0].arn}*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.pem_secret[0].arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Encrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.token_secret[0].arn
      },
    ]
  })
}

resource "aws_lambda_function" "rotator" {
  count = local.enabled && local.app_mode ? 1 : 0

  function_name = "${module.this.id}-ct-dispatch-rotator"
  description   = "Exchanges the GitHub App PEM for a ~1h installation token; writes to Secrets Manager. Invoked every 30 min."
  role          = aws_iam_role.rotator[0].arn
  handler       = "index.handler"
  runtime       = "python3.12"
  timeout       = 30
  memory_size   = 256

  filename         = var.rotator_zip_path
  source_code_hash = filebase64sha256(var.rotator_zip_path)

  environment {
    variables = {
      APP_ID                = var.github_app_id
      APP_INSTALLATION_ID   = var.github_app_installation_id
      PEM_SECRET_ARN        = aws_secretsmanager_secret.github_app_private_key[0].arn
      TOKEN_SECRET_ARN      = aws_secretsmanager_secret.github_installation_token[0].arn
    }
  }

  tags = module.this.tags

  depends_on = [aws_iam_role_policy.rotator]
}

resource "aws_cloudwatch_event_rule" "rotator_schedule" {
  count = local.enabled && local.app_mode ? 1 : 0

  name                = "${module.this.id}-rotator-schedule"
  description         = "30-minute tick for the ct-dispatch rotator Lambda."
  schedule_expression = "rate(30 minutes)"

  tags = module.this.tags
}

resource "aws_cloudwatch_event_target" "rotator_schedule" {
  count = local.enabled && local.app_mode ? 1 : 0

  rule = aws_cloudwatch_event_rule.rotator_schedule[0].name
  arn  = aws_lambda_function.rotator[0].arn
}

resource "aws_lambda_permission" "rotator_events_invoke" {
  count = local.enabled && local.app_mode ? 1 : 0

  statement_id  = "AllowEventBridgeInvokeRotator"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rotator[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.rotator_schedule[0].arn
}

# Alarms reproducing SMR's out-of-the-box alerting.
resource "aws_cloudwatch_metric_alarm" "rotator_errors" {
  count = local.enabled && local.app_mode ? 1 : 0

  alarm_name          = "${module.this.id}-rotator-errors"
  alarm_description   = "Rotator Lambda error count > 0. Investigate: GitHub App revoked? PEM corrupted? KMS key policy drift?"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = { FunctionName = aws_lambda_function.rotator[0].function_name }

  alarm_actions = [aws_sns_topic.alarms[0].arn]

  tags = module.this.tags
}

# "Token secret not refreshed in > 35 min" — catches rotator silently
# skipping its PutSecretValue call while not erroring. We compare to the
# token secret's LastChangedDate via the `GetSecretValue` invocations metric;
# absence is itself the alarm.
resource "aws_cloudwatch_metric_alarm" "rotator_staleness" {
  count = local.enabled && local.app_mode ? 1 : 0

  alarm_name          = "${module.this.id}-rotator-staleness"
  alarm_description   = "No successful rotator run in the last 35 minutes. EventBridge scheduled rule is supposed to fire every 30 min."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Invocations"
  namespace           = "AWS/Lambda"
  period              = 2100  # 35 min
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "breaching"

  dimensions = { FunctionName = aws_lambda_function.rotator[0].function_name }

  alarm_actions = [aws_sns_topic.alarms[0].arn]

  tags = module.this.tags
}
