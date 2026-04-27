# Regression guard for the single-rule refactor. The component previously
# split into one rule per CT eventName (for per-event input_transformer
# paths); that was collapsed to a single rule using the reserved
# <aws.events.event> placeholder. This test locks in the new shape: one
# rule, one target, all three eventNames matched via event_pattern.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_secretsmanager_secret_version" {
    defaults = {
      secret_string = "test-token"
    }
  }
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_id  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    }
  }
}

variables {
  region            = "us-east-1"
  namespace         = "test"
  stage             = "test"
  name              = "ct-eb"
  github_org        = "acme"
  github_repo       = "atmos-aft"
  github_auth_mode  = "pat"
  github_pat_base64 = "dGVzdA=="
}

run "exactly_one_rule_covers_all_three_event_names" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_event_rule.ct_lifecycle) == 1
    error_message = "Post-refactor there must be exactly ONE event rule - the three CT lifecycle events are merged via event_pattern. A value of 3 here means the for_each split regressed."
  }

  # event_pattern is a JSON string at plan time. Assert it references all
  # three eventNames the GHA consumer dispatches on.
  assert {
    condition = alltrue([
      can(regex("CreateManagedAccount", aws_cloudwatch_event_rule.ct_lifecycle[0].event_pattern)),
      can(regex("UpdateManagedAccount", aws_cloudwatch_event_rule.ct_lifecycle[0].event_pattern)),
      can(regex("RegisterOrganizationalUnit", aws_cloudwatch_event_rule.ct_lifecycle[0].event_pattern)),
    ])
    error_message = "event_pattern must match all three CT lifecycle eventNames."
  }

  assert {
    condition     = can(regex("aws.controltower", aws_cloudwatch_event_rule.ct_lifecycle[0].event_pattern))
    error_message = "event_pattern source must be aws.controltower."
  }
}

run "target_uses_raw_event_placeholder" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_event_target.github_dispatch) == 1
    error_message = "Exactly one target - matches the single-rule topology."
  }

  # The reserved <aws.events.event> placeholder is how we embed the full CT
  # event as client_payload; losing it would silently replace the payload
  # with an empty object and all downstream workflow branching would fail.
  assert {
    condition = can(regex(
      "<aws\\.events\\.event>",
      aws_cloudwatch_event_target.github_dispatch[0].input_transformer[0].input_template
    ))
    error_message = "input_template must embed the reserved <aws.events.event> placeholder - without it client_payload loses the full event detail."
  }

  # event_type is the repository_dispatch type GH workflows subscribe to.
  # Changing this requires a matching change in ct-lifecycle-event.yaml.
  assert {
    condition = can(regex(
      "\"event_type\":\\s*\"ct-lifecycle\"",
      aws_cloudwatch_event_target.github_dispatch[0].input_transformer[0].input_template
    ))
    error_message = "input_template must declare event_type=ct-lifecycle; the consumer workflow listens on exactly this type."
  }
}

run "connection_ignores_auth_parameters_drift" {
  command = plan

  # Sanity: the connection resource exists. The ignore_changes on
  # auth_parameters (preventing rotator-induced drift) is a configuration
  # setting terraform test cannot easily read, but the resource's presence
  # at plan time is the first-order guard.
  assert {
    condition     = length(aws_cloudwatch_event_connection.github) == 1
    error_message = "EventBridge API destination connection must be declared."
  }
}
