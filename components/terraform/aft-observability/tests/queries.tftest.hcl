# The component is intentionally thin: it only saves CloudWatch Logs Insights
# queries from var.queries. These tests lock in the contract:
#   - Empty map produces zero query definitions.
#   - Each map entry produces one definition.
#   - Names are namespaced by module.this.id (i.e. context-prefixed).
#   - log_group_names + query_string flow through unchanged.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-observability"
}

run "empty_queries_map_produces_no_definitions" {
  command = plan

  variables {
    queries = {}
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.saved) == 0
    error_message = "Empty queries map must produce zero query definitions."
  }
}

run "each_query_entry_produces_one_definition" {
  command = plan

  variables {
    queries = {
      account_id_query = {
        log_group_names = ["/aws/lambda/aft-account-request"]
        query_string    = "fields @timestamp, @message | filter @message like /account_id/"
      }
      customization_request_query = {
        log_group_names = ["/aws/lambda/aft-customizations"]
        query_string    = "fields @timestamp, @message | filter @message like /customization/"
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.saved) == 2
    error_message = "Two queries in the input map must produce exactly two query definitions."
  }
}

run "query_name_is_context_prefixed" {
  command = plan

  variables {
    queries = {
      account_id_query = {
        log_group_names = ["/aws/lambda/aft-account-request"]
        query_string    = "fields @timestamp, @message"
      }
    }
  }

  # name = "${module.this.id}/${each.key}". With null-label defaults
  # (delimiter = "-"), id resolves to "test-test-aft-observability".
  assert {
    condition     = aws_cloudwatch_query_definition.saved["account_id_query"].name == "test-test-aft-observability/account_id_query"
    error_message = "Query name must be the context-id prefix joined with the map key by '/' — prevents collisions across stages."
  }
}

run "log_group_names_and_query_string_flow_through" {
  command = plan

  variables {
    queries = {
      probe = {
        log_group_names = ["/aws/lambda/foo", "/aws/lambda/bar"]
        query_string    = "fields @timestamp"
      }
    }
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.saved["probe"].log_group_names) == 2
    error_message = "log_group_names list must propagate from the queries map verbatim."
  }

  assert {
    condition     = aws_cloudwatch_query_definition.saved["probe"].query_string == "fields @timestamp"
    error_message = "query_string must propagate from the queries map verbatim."
  }
}
