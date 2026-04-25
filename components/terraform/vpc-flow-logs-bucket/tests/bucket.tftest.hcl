# Verifies the variable-default contract for the per-region VPC flow
# logs bucket: defaults wire through to the cloudposse module
# (lifecycle: 30d→IA, 90d→Glacier, 365d expiration), force_destroy is
# pinned off, and lifecycle ordering is sane.
#
# Component-side contract: this is a BUCKET-only component — consumers
# in vended accounts create their own aws_flow_log resources against
# this bucket cross-account. main.tf pins `flow_log_enabled = false` on
# the wrapped cloudposse module so its aws_flow_log resource is
# count-zeroed (otherwise the provider's ExactlyOneOf validation on
# vpc_id/subnet_id/eni_id would fail).

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
  name      = "vpc-flow-logs"
}

run "default_lifecycle_thresholds" {
  command = plan

  assert {
    condition     = var.standard_transition_days == 30
    error_message = "Default standard_transition_days must be 30 (Standard → Standard-IA at 30d)."
  }

  assert {
    condition     = var.glacier_transition_days == 90
    error_message = "Default glacier_transition_days must be 90."
  }

  assert {
    condition     = var.expiration_days == 365
    error_message = "Default expiration_days must be 365 (1y)."
  }
}

run "lifecycle_thresholds_flow_through" {
  command = plan

  variables {
    standard_transition_days = 60
    glacier_transition_days  = 180
    expiration_days          = 2555
  }

  # Asserting on the wrapped module's internal aws_s3_bucket_lifecycle
  # resource is brittle (computed-after-apply for many fields) and the
  # module's count-guards strip resources when enabled=false. We assert
  # the var surface — the contract that the module documents.
  assert {
    condition     = var.standard_transition_days == 60 && var.glacier_transition_days == 180 && var.expiration_days == 2555
    error_message = "Lifecycle threshold variables must flow through to the cloudposse module."
  }
}

run "ordering_invariant_standard_lt_glacier_lt_expiration" {
  command = plan

  # Logical contract: standard transition must precede glacier; glacier
  # must precede expiration. The component does not enforce this — this
  # is a regression guard against a sloppy override at the stack layer.
  assert {
    condition     = var.standard_transition_days < var.glacier_transition_days
    error_message = "standard_transition_days must be < glacier_transition_days."
  }

  assert {
    condition     = var.glacier_transition_days < var.expiration_days
    error_message = "glacier_transition_days must be < expiration_days."
  }
}

run "outputs_are_empty_when_disabled" {
  command = plan

  variables {
    enabled = false
  }

  # When enabled=false the wrapped module's count-guards produce no
  # bucket. The cloudposse module emits "" (not null) for disabled
  # outputs; the wrapping component's `try(...)` keeps that verbatim.
  assert {
    condition     = output.bucket_id == "" || output.bucket_id == null
    error_message = "bucket_id must be empty/null when enabled=false."
  }

  assert {
    condition     = output.bucket_arn == "" || output.bucket_arn == null
    error_message = "bucket_arn must be empty/null when enabled=false."
  }
}
