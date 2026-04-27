locals {
  enabled = module.this.enabled

  # Secret names are consistent across modes so ops can read docs once.
  app_pem_secret_name   = "atmos-aft/ct-dispatch/github-app-private-key"
  app_token_secret_name = "atmos-aft/ct-dispatch/github-installation-token"
  pat_secret_name       = "atmos-aft/ct-dispatch/github-pat"

  # Which secret feeds the EventBridge connection.
  connection_secret_name = var.github_auth_mode == "app" ? local.app_token_secret_name : local.pat_secret_name

  # GitHub dispatch endpoint - one repo, one URL.
  github_dispatch_url = "https://api.github.com/repos/${var.github_org}/${var.github_repo}/dispatches"

  # CT lifecycle event names we fan out. The three events have heterogeneous
  # serviceEventDetails shapes (createManagedAccountStatus,
  # updateManagedAccountStatus, registerOrganizationalUnitStatus), so a single
  # input_transformer cannot bind typed fields across all three. We pass the
  # full raw event as client_payload via the reserved <aws.events.event>
  # placeholder and let the GHA workflow branch on detail.eventName.
  ct_event_names = [
    "CreateManagedAccount",
    "UpdateManagedAccount",
    "RegisterOrganizationalUnit",
  ]
}

# ---------------------------------------------------------------------------
# EventBridge rules on CT management default bus
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_event_rule" "ct_lifecycle" {
  count = local.enabled ? 1 : 0

  name           = "${module.this.id}-ct-lifecycle"
  description    = "Forwards Control Tower lifecycle events (CreateManagedAccount, UpdateManagedAccount, RegisterOrganizationalUnit) to the GitHub repository_dispatch endpoint as event_type=ct-lifecycle."
  event_bus_name = "default"
  event_pattern = jsonencode({
    source      = ["aws.controltower"]
    detail-type = ["AWS Service Event via CloudTrail"]
    detail = {
      eventSource = ["controltower.amazonaws.com"]
      eventName   = local.ct_event_names
    }
  })

  tags = module.this.tags
}

resource "aws_cloudwatch_event_target" "github_dispatch" {
  count = local.enabled ? 1 : 0

  rule           = aws_cloudwatch_event_rule.ct_lifecycle[0].name
  arn            = aws_cloudwatch_event_api_destination.github_dispatch[0].arn
  role_arn       = aws_iam_role.eventbridge_invoke[0].arn
  event_bus_name = "default"

  # The <aws.events.event> placeholder expands to the full raw CT event JSON.
  # We embed it verbatim as client_payload; the consumer workflow branches on
  # detail.eventName and walks the per-event serviceEventDetails path. This
  # keeps terraform agnostic to CT event shape - new CT lifecycle events can
  # be added to local.ct_event_names without changing any input_paths.
  input_transformer {
    input_template = <<-EOT
      {
        "event_type": "ct-lifecycle",
        "client_payload": <aws.events.event>
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

  # The api_key.value is sourced from Secrets Manager and rewritten by the
  # rotator Lambda every ~30 min. Ignore downstream drift so plan stays clean.
  lifecycle {
    ignore_changes = [auth_parameters]
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
