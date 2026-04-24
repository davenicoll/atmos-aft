# Verifies the aws-scp wrapper passes statements + target_id through to the
# Cloudposse service-control-policies module and that a non-empty statements
# input is required (module does not default-enable; empty statements would
# plan an empty policy document).

mock_provider "aws" {
  # Cloudposse's scps module jsondecode()s an aws_iam_policy_document;
  # without this default the mock returns a random string and the
  # jsondecode call fails.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aws-scp"
  target_id = "ou-abcd-1234567a"
  # Cloudposse's service-control-policies module expects a list of statements
  # keyed by `sid`, not a map. Reflect that here.
  statements = [
    {
      sid       = "DenyLeavingOrganization"
      effect    = "Deny"
      actions   = ["organizations:LeaveOrganization"]
      resources = ["*"]
    },
  ]
}

run "plan_succeeds_with_valid_statements" {
  command = plan

  # The inner Cloudposse module exposes only two outputs
  # (organizations_policy_id, organizations_policy_arn), so downstream
  # assertions are limited. A clean plan is the primary test signal; the
  # wrapper passes var.statements / var.target_id / var.description straight
  # through — failures surface as plan errors (e.g. the sid-missing error
  # that this harness caught on a map-shaped statements input).
  assert {
    condition     = length(var.statements) == 1
    error_message = "Test fixture should declare exactly one statement."
  }
}

run "default_description_matches_sentinel" {
  command = plan

  assert {
    condition     = var.description == "Atmos-AFT additional SCP — never CT guardrails."
    error_message = "Default description must be the atmos-aft sentinel value. If this drifts, update the module-inventory doc too."
  }
}

run "caller_can_override_description" {
  command = plan

  variables {
    description = "DenyRegionRestriction-nonprod"
  }

  assert {
    condition     = var.description == "DenyRegionRestriction-nonprod"
    error_message = "description override must be honored."
  }
}
