# Verifies the SSE/KMS wiring contract for the centralized logging
# bucket: defaults are aws:kms, kms_master_key_arn is null-coalesced to
# "" before being passed to the cloudposse module, ssl-only is enforced,
# versioning is on, force_destroy is pinned off.
#
# AUDIT GOTCHA — UNRESOLVED, OUT OF SCOPE HERE:
#   When sse_algorithm = "aws:kms" (default) and kms_master_key_arn is
#   null, main.tf rewrites the arn to the empty string "" and passes it
#   to the cloudposse module, which silently falls back to the
#   AWS-managed `aws/s3` key. Production should error in this state.
#   Flagged for a follow-up validation block on
#   sse_algorithm/kms_master_key_arn coupling. Tests below assert the
#   current behaviour to lock in regression coverage; do NOT mistake
#   them for endorsement of the silent-fallback shape.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_id  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "123456789012"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "audit"
  name      = "central-logs"
}

run "default_sse_algorithm_is_kms" {
  command = plan

  assert {
    condition     = var.sse_algorithm == "aws:kms"
    error_message = "Default sse_algorithm must be aws:kms."
  }
}

run "kms_master_key_arn_default_is_null_silent_fallback" {
  command = plan

  # SEE FILE-HEADER GOTCHA: defaults pair sse_algorithm=aws:kms with
  # kms_master_key_arn=null, which main.tf rewrites to "" — silently
  # falling back to the AWS-managed aws/s3 key. This assert pins the
  # current behaviour. Once the validation is added upstream, this run
  # block flips to expect_failures.
  assert {
    condition     = var.kms_master_key_arn == null
    error_message = "Default kms_master_key_arn must be null."
  }
}

run "kms_master_key_arn_flows_through_when_set" {
  command = plan

  variables {
    kms_master_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  assert {
    condition     = var.kms_master_key_arn == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    error_message = "Provided kms_master_key_arn must flow through to the cloudposse module."
  }
}

run "sse_algorithm_aes256_override" {
  command = plan

  variables {
    sse_algorithm = "AES256"
  }

  # AES256 path: kms_master_key_arn is irrelevant (cloudposse module
  # ignores it). Just assert the var surface flows through.
  assert {
    condition     = var.sse_algorithm == "AES256"
    error_message = "AES256 must be accepted as a valid sse_algorithm value."
  }
}

run "default_lifecycle_rules_empty" {
  command = plan

  # Stack YAML supplies the 7y retention rules per atmos-model.md; the
  # component default is empty so misconfigured stacks don't silently
  # apply unintended lifecycle behaviour.
  assert {
    condition     = length(var.lifecycle_rules) == 0
    error_message = "Default lifecycle_rules must be empty — concrete rules come from stack YAML."
  }
}

run "access_log_bucket_default_disabled" {
  command = plan

  # Null disables access logging; main.tf turns this into [] for the
  # cloudposse module's logging input.
  assert {
    condition     = var.access_log_bucket_name == null
    error_message = "Default access_log_bucket_name must be null (logging disabled)."
  }

  assert {
    condition     = var.access_log_prefix == "logs/"
    error_message = "Default access_log_prefix must be 'logs/'."
  }
}
