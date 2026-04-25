# Verifies the aws_cloudtrail_event_data_store contract: name from
# module.this.id, default ~7-year retention (2555d, the AWS provider
# cap), single-region by default, termination protection on, kms_key_id
# pass-through, and the four advanced-event-selector event sources
# (controltower, organizations, servicecatalog, sts).

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "cloudtrail-lake"
}

run "retention_period_flows_through" {
  command = plan

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].retention_period == 2555
    error_message = "var.retention_days must flow into aws_cloudtrail_event_data_store.retention_period."
  }
}

run "single_region_and_termination_protection_defaults" {
  command = plan

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].multi_region_enabled == false
    error_message = "Default must be single-region; multi-region is opt-in via var.multi_region_enabled."
  }

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].termination_protection_enabled == true
    error_message = "Termination protection must be enabled — the store holds 7y of audit data."
  }

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].organization_enabled == false
    error_message = "organization_enabled must be false — Atmos-AFT runs the store in the audit account, not the org root."
  }
}

run "kms_key_id_flows_through_when_set" {
  command = plan

  variables {
    kms_key_id = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  }

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    error_message = "var.kms_key_id must flow through to aws_cloudtrail_event_data_store.kms_key_id."
  }
}

run "default_kms_key_id_is_null_aws_managed" {
  command = plan

  assert {
    condition     = aws_cloudtrail_event_data_store.this[0].kms_key_id == null
    error_message = "Default kms_key_id must be null (uses AWS-managed CloudTrail key)."
  }
}

run "advanced_event_selector_pins_four_event_sources" {
  command = plan

  # field_selector is a set(object) — not addressable by index. Flatten
  # to a single map keyed by `field`, and verify membership of each
  # event-source alongside the eventCategory pin.
  assert {
    condition = contains(
      flatten([
        for fs in aws_cloudtrail_event_data_store.this[0].advanced_event_selector[0].field_selector :
        fs.equals if fs.field == "eventSource"
      ]),
      "controltower.amazonaws.com"
    )
    error_message = "advanced_event_selector must include controltower.amazonaws.com."
  }

  assert {
    condition = contains(
      flatten([
        for fs in aws_cloudtrail_event_data_store.this[0].advanced_event_selector[0].field_selector :
        fs.equals if fs.field == "eventSource"
      ]),
      "organizations.amazonaws.com"
    )
    error_message = "advanced_event_selector must include organizations.amazonaws.com."
  }

  assert {
    condition = contains(
      flatten([
        for fs in aws_cloudtrail_event_data_store.this[0].advanced_event_selector[0].field_selector :
        fs.equals if fs.field == "eventSource"
      ]),
      "servicecatalog.amazonaws.com"
    )
    error_message = "advanced_event_selector must include servicecatalog.amazonaws.com."
  }

  assert {
    condition = contains(
      flatten([
        for fs in aws_cloudtrail_event_data_store.this[0].advanced_event_selector[0].field_selector :
        fs.equals if fs.field == "eventSource"
      ]),
      "sts.amazonaws.com"
    )
    error_message = "advanced_event_selector must include sts.amazonaws.com."
  }

  assert {
    condition = contains(
      flatten([
        for fs in aws_cloudtrail_event_data_store.this[0].advanced_event_selector[0].field_selector :
        fs.equals if fs.field == "eventCategory"
      ]),
      "Management"
    )
    error_message = "eventCategory field_selector must pin to Management."
  }
}

run "rejects_retention_below_minimum" {
  command = plan

  variables {
    retention_days = 6
  }

  expect_failures = [
    var.retention_days,
  ]
}

run "rejects_retention_above_maximum" {
  command = plan

  variables {
    retention_days = 2556 # one above the AWS provider plan-time cap (2555)
  }

  expect_failures = [
    var.retention_days,
  ]
}
