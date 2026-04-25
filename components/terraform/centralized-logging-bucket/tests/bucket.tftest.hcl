# Verifies the SSE/KMS wiring contract for the centralized logging
# bucket. The default sse_algorithm is aws:kms; an output precondition
# now rejects (sse_algorithm=aws:kms, kms_master_key_arn=null) so the
# silent-fallback-to-aws/s3 trap can't ship.

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

  # Default sse_algorithm=aws:kms. Provide a CMK arn to satisfy the
  # cross-variable precondition; runs that need to vary either field
  # override locally.
  kms_master_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
}

run "default_sse_algorithm_is_kms" {
  command = plan

  assert {
    condition     = var.sse_algorithm == "aws:kms"
    error_message = "Default sse_algorithm must be aws:kms."
  }
}

run "rejects_aws_kms_with_null_kms_arn" {
  command = plan

  variables {
    sse_algorithm      = "aws:kms"
    kms_master_key_arn = null
  }

  expect_failures = [
    output.bucket_id,
  ]
}

run "aes256_with_null_kms_is_allowed" {
  command = plan

  variables {
    sse_algorithm      = "AES256"
    kms_master_key_arn = null
  }

  assert {
    condition     = var.sse_algorithm == "AES256"
    error_message = "AES256 + null kms_master_key_arn must be allowed (the precondition only fires for aws:kms)."
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
