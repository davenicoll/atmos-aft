# IAM role EventBridge assumes when invoking the API destination.
# Needs: invoke API destination, read the connection's current secret value.

resource "aws_iam_role" "eventbridge_invoke" {
  count = local.enabled ? 1 : 0

  name = "${module.this.id}-ct-dispatch-eventbridge"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = module.this.tags
}

data "aws_iam_policy_document" "eventbridge_invoke" {
  statement {
    sid       = "InvokeApiDestination"
    effect    = "Allow"
    actions   = ["events:InvokeApiDestination"]
    resources = [aws_cloudwatch_event_api_destination.github_dispatch[0].arn]
  }

  # Only the selected-mode secret; never both. Connection role reads the value
  # every invocation so EventBridge can populate the Authorization header.
  statement {
    sid     = "ReadConnectionSecret"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      local.app_mode
        ? "${aws_secretsmanager_secret.github_installation_token[0].arn}*"
        : "${aws_secretsmanager_secret.github_pat[0].arn}*",
    ]
  }

  # App mode only: need Decrypt on the token CMK.
  dynamic "statement" {
    for_each = local.app_mode ? [1] : []
    content {
      sid       = "DecryptTokenSecret"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [aws_kms_key.token_secret[0].arn]
    }
  }
}

resource "aws_iam_role_policy" "eventbridge_invoke" {
  count = local.enabled ? 1 : 0

  name   = "EventBridgeInvokeAndReadSecret"
  role   = aws_iam_role.eventbridge_invoke[0].id
  policy = data.aws_iam_policy_document.eventbridge_invoke.json
}
