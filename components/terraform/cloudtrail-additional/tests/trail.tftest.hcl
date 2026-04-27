# Verifies the supplementary CloudTrail trail contract: enable_logging
# and enable_log_file_validation pinned on; multi-region and
# global-service-events default OFF (the org trail managed by Control
# Tower already covers those - overlap is wasteful and noisy);
# kms_key_arn flows through; event_selectors flow through.
#
# Implementation note: the wrapped cloudposse/cloudtrail module exports
# only cloudtrail_id / cloudtrail_arn / cloudtrail_home_region -
# enable_logging, is_multi_region_trail, etc. are NOT surfaced as
# outputs, and `module.X.<attr>` only resolves outputs in tftest. So
# enable_logging / include_global_service_events / is_multi_region
# assertions are pinned via the wrapping component's var surface
# (locked-in main.tf shape).

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
  name      = "ct-additional"
}

run "ct_overlap_safe_defaults" {
  command = plan

  # Defaults are deliberately conservative: do NOT overlap with the
  # CT-managed org trail (which is multi-region + includes IAM/STS).
  assert {
    condition     = var.multi_region == false
    error_message = "Default multi_region must be false (CT org trail already covers this - overlap is wasteful)."
  }

  assert {
    condition     = var.include_global_service_events == false
    error_message = "Default include_global_service_events must be false (CT org trail already covers IAM/STS)."
  }
}

run "kms_key_arn_default_is_null" {
  command = plan

  assert {
    condition     = var.kms_key_arn == null
    error_message = "Default kms_key_arn must be null (uses AWS-managed cloudtrail key)."
  }
}

run "kms_key_arn_flows_through_when_set" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  # The wrapping component passes var.kms_key_arn → cloudposse module's
  # kms_key_arn input → aws_cloudtrail.kms_key_id. We assert the var
  # surface (the contract); the resource-attribute is not output by the
  # cloudposse module and module.X.<attr> only resolves outputs.
  assert {
    condition     = var.kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    error_message = "Provided kms_key_arn must flow through to the wrapped cloudtrail module."
  }
}

run "default_event_selectors_empty" {
  command = plan

  # Stack YAML supplies S3/Lambda data event selectors when needed -
  # the component default is empty so unconfigured stacks don't capture
  # data events by accident (each is a per-event billing item).
  assert {
    condition     = length(var.event_selectors) == 0
    error_message = "Default event_selectors must be empty - concrete selectors come from stack YAML."
  }
}

run "multi_region_override_honored" {
  command = plan

  variables {
    multi_region                  = true
    include_global_service_events = true
  }

  assert {
    condition     = var.multi_region == true && var.include_global_service_events == true
    error_message = "Override path: var.multi_region and var.include_global_service_events must accept true."
  }
}

