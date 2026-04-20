locals {
  enabled = module.this.enabled

  # Secret names are consistent across modes so ops can read docs once.
  app_pem_secret_name   = "atmos-aft/ct-dispatch/github-app-private-key"
  app_token_secret_name = "atmos-aft/ct-dispatch/github-installation-token"
  pat_secret_name       = "atmos-aft/ct-dispatch/github-pat"

  # Which secret feeds the EventBridge connection.
  connection_secret_name = var.github_auth_mode == "app" ? local.app_token_secret_name : local.pat_secret_name

  # GitHub dispatch endpoint — one repo, one URL.
  github_dispatch_url = "https://api.github.com/repos/${var.github_org}/${var.github_repo}/dispatches"

  # CT event patterns we forward. Matches aws.controltower service events
  # that carry account-lifecycle semantics.
  event_pattern = jsonencode({
    source = ["aws.controltower"]
    detail-type = [
      "AWS Service Event via CloudTrail",
    ]
    detail = {
      eventSource = ["controltower.amazonaws.com"]
      eventName = [
        "CreateManagedAccount",
        "UpdateManagedAccount",
        "RegisterOrganizationalUnit",
      ]
    }
  })
}

# ---------------------------------------------------------------------------
# EventBridge rule on CT management default bus
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ct_lifecycle" {
  count = local.enabled ? 1 : 0

  name           = "${module.this.id}-ct-lifecycle"
  description    = "Forwards Control Tower lifecycle events to the GitHub repository_dispatch endpoint for the atmos-aft workflow."
  event_bus_name = "default"
  event_pattern  = local.event_pattern

  tags = module.this.tags
}

resource "aws_cloudwatch_event_target" "github_dispatch" {
  count = local.enabled ? 1 : 0

  rule           = aws_cloudwatch_event_rule.ct_lifecycle[0].name
  arn            = aws_cloudwatch_event_api_destination.github_dispatch[0].arn
  role_arn       = aws_iam_role.eventbridge_invoke[0].arn
  event_bus_name = "default"

  # Map the CT event body into the GitHub dispatch payload.
  # Event types are dynamic per CT event name, handled by the downstream workflow.
  input_transformer {
    input_paths = {
      event_id               = "$.id"
      event_name             = "$.detail.eventName"
      account_id             = "$.detail.serviceEventDetails.createManagedAccountStatus.account.accountId"
      account_email          = "$.detail.serviceEventDetails.createManagedAccountStatus.account.accountEmail"
      ou_name                = "$.detail.serviceEventDetails.createManagedAccountStatus.organizationalUnit.organizationalUnitName"
      ou_id                  = "$.detail.serviceEventDetails.createManagedAccountStatus.organizationalUnit.organizationalUnitId"
      provisioned_product_id = "$.detail.serviceEventDetails.createManagedAccountStatus.provisionedProductId"
    }
    input_template = <<-EOT
      {
        "event_type": "ct-<event_name>",
        "client_payload": {
          "event_id": <event_id>,
          "event_name": <event_name>,
          "account_id": <account_id>,
          "account_email": <account_email>,
          "ou_name": <ou_name>,
          "ou_id": <ou_id>,
          "provisioned_product_id": <provisioned_product_id>
        }
      }
    EOT
  }

  # Durable-delivery surface: DLQ catches anything EventBridge can't deliver
  # within the API destination's built-in 24h/185-attempt budget. 14-day SQS
  # retention buys cover for a Fri→Mon rotator outage. See gha-design.md §5.12.
  dead_letter_config {
    arn = aws_sqs_queue.dlq[0].arn
  }

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 4
  }
}

# ---------------------------------------------------------------------------
# API destination + connection (GitHub dispatch endpoint)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_connection" "github" {
  count = local.enabled ? 1 : 0

  name               = "${module.this.id}-github-dispatch"
  description        = "GitHub repository_dispatch connection for CT lifecycle fan-out (mode: ${var.github_auth_mode})"
  authorization_type = "API_KEY"

  auth_parameters {
    api_key {
      key   = "Authorization"
      value = "Bearer ${data.aws_secretsmanager_secret_version.connection_token[0].secret_string}"
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "github_dispatch" {
  count = local.enabled ? 1 : 0

  name                             = "${module.this.id}-github-dispatch"
  description                      = "POST to GitHub repository_dispatch for ${var.github_org}/${var.github_repo}"
  invocation_endpoint              = local.github_dispatch_url
  http_method                      = "POST"
  connection_arn                   = aws_cloudwatch_event_connection.github[0].arn
  invocation_rate_limit_per_second = 10
}

# ---------------------------------------------------------------------------
# Lookup the connection secret so its current value feeds the connection
# ---------------------------------------------------------------------------

data "aws_secretsmanager_secret" "connection_token" {
  count = local.enabled ? 1 : 0
  name  = local.connection_secret_name

  depends_on = [
    aws_secretsmanager_secret.github_installation_token,
    aws_secretsmanager_secret.github_pat,
  ]
}

data "aws_secretsmanager_secret_version" "connection_token" {
  count     = local.enabled ? 1 : 0
  secret_id = data.aws_secretsmanager_secret.connection_token[0].id
}
