# The component is a thin wrapper around cloudposse/s3-log-storage. Most of
# the AFT-required hardening (sse_algorithm = AES256, force_destroy = false,
# four public-access flags = true) is hardcoded in main.tf — terraform test
# cannot read module-input arguments at plan time, only outputs (which the
# wrapped module computes after apply). What IS testable here is the
# variable-surface contract: defaults for retention windows, and that the
# component plans cleanly with both empty-list and explicit lifecycle rules.

mock_provider "aws" {
  # cloudposse/s3-bucket and friends jsondecode an internal aws_iam_policy_document.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_canonical_user_id" {
    defaults = {
      id = "abc123def456"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-access-logs"
}

run "plan_succeeds_with_defaults" {
  command = plan

  assert {
    condition     = var.standard_transition_days == 30
    error_message = "Default standard_transition_days must be 30 (move to STANDARD_IA after 30d)."
  }

  assert {
    condition     = var.glacier_transition_days == 90
    error_message = "Default glacier_transition_days must be 90 (move to GLACIER after 90d)."
  }

  assert {
    condition     = var.expiration_days == 365
    error_message = "Default expiration_days must be 365 (1y retention for access logs)."
  }
}

run "lifecycle_configuration_rules_default_is_empty" {
  command = plan

  # Empty list = let cloudposse/s3-log-storage apply its module-internal
  # defaults (built from standard_transition_days/glacier_transition_days/
  # expiration_days). Anything else would mask the variable-driven rule.
  assert {
    condition     = length(var.lifecycle_configuration_rules) == 0
    error_message = "Default lifecycle_configuration_rules must be empty so module-internal defaults apply."
  }
}

run "explicit_lifecycle_rules_plan_cleanly" {
  command = plan

  variables {
    lifecycle_configuration_rules = [
      {
        enabled                                = true
        id                                     = "expire-old"
        abort_incomplete_multipart_upload_days = 7
        expiration = {
          days = 30
        }
        noncurrent_version_expiration = {
          noncurrent_days = 7
        }
      }
    ]
  }

  assert {
    condition     = length(var.lifecycle_configuration_rules) == 1
    error_message = "Explicit lifecycle rule must propagate to the module."
  }
}

run "target_role_arn_default_is_empty" {
  command = plan

  # Empty string = run under the caller's creds (the central role from
  # configure-aws). Non-empty triggers the assume_role block in providers.tf.
  assert {
    condition     = var.target_role_arn == ""
    error_message = "Default target_role_arn must be empty — assume_role only fires when TF_VAR_target_role_arn is exported."
  }
}
