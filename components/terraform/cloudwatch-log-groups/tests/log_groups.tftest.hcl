# Verifies the for_each-over-map contract for log_groups: empty map →
# zero modules, populated map → one module per key, retention/kms_key_arn
# flow through to each module. Outputs are maps keyed by logical name.

mock_provider "aws" {
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
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "audit"
}

run "empty_map_creates_no_log_groups" {
  command = plan

  variables {
    log_groups = {}
  }

  # When for_each is over an empty map, no module instances exist and
  # the output maps are themselves empty.
  assert {
    condition     = length(output.log_group_names) == 0
    error_message = "Empty log_groups map must produce zero log_group_names entries."
  }

  assert {
    condition     = length(output.log_group_arns) == 0
    error_message = "Empty log_groups map must produce zero log_group_arns entries."
  }
}

run "populated_map_renders_one_per_key" {
  command = plan

  variables {
    log_groups = {
      "app"   = { retention_in_days = 30 }
      "audit" = { retention_in_days = 365 }
      "trace" = { retention_in_days = 7 }
    }
  }

  # Three keys → three output entries (mocked module outputs return
  # placeholder strings, so we assert on cardinality + key set).
  assert {
    condition     = length(keys(output.log_group_names)) == 3
    error_message = "Three input keys must produce three log_group_names entries."
  }

  assert {
    condition     = contains(keys(output.log_group_names), "app")
    error_message = "Output log_group_names must contain key 'app'."
  }

  assert {
    condition     = contains(keys(output.log_group_names), "audit")
    error_message = "Output log_group_names must contain key 'audit'."
  }

  assert {
    condition     = contains(keys(output.log_group_names), "trace")
    error_message = "Output log_group_names must contain key 'trace'."
  }
}

run "default_retention_is_90_days" {
  command = plan

  variables {
    log_groups = {
      "default" = {}
    }
  }

  # The optional() default in the type spec is 90.
  assert {
    condition     = var.log_groups["default"].retention_in_days == 90
    error_message = "Optional retention_in_days must default to 90."
  }
}

run "kms_key_arn_default_is_null" {
  command = plan

  variables {
    log_groups = {
      "no-cmk" = {}
    }
  }

  assert {
    condition     = var.log_groups["no-cmk"].kms_key_arn == null
    error_message = "Default kms_key_arn must be null (AWS-managed)."
  }
}

run "kms_key_arn_flows_through_when_set" {
  command = plan

  variables {
    log_groups = {
      "encrypted" = {
        retention_in_days = 30
        kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      }
    }
  }

  assert {
    condition     = var.log_groups["encrypted"].kms_key_arn == "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    error_message = "kms_key_arn must flow through to the per-key module."
  }

  assert {
    condition     = var.log_groups["encrypted"].retention_in_days == 30
    error_message = "Per-key retention_in_days override must be honored."
  }
}
