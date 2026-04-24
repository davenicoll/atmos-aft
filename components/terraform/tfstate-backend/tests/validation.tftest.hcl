# Primarily validates the user-facing contract that can be exercised without
# the underlying cloudposse/tfstate-backend module actually planning — the
# module itself wraps many AWS data sources whose return values are
# mocked here, so bucket/key attributes fall out of scope for plan-time
# assertions. What IS testable: variable validation + the kms_alias output
# (a pure-computed local).

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
  mock_data "aws_kms_alias" {
    defaults = {
      target_key_id  = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      target_key_arn = "arn:aws:kms:us-east-1:123456789012:key/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    }
  }
}

variables {
  region              = "us-east-1"
  namespace           = "test"
  stage               = "test"
  name                = "tfstate-backend"
  aft_mgmt_account_id = "123456789012"
}

run "default_kms_alias_is_atmos_tfstate" {
  command = plan

  assert {
    condition     = output.kms_alias_name == "alias/atmos-tfstate"
    error_message = "Default KMS alias must be 'alias/atmos-tfstate' — the atmos-model.md baseline."
  }
}

run "kms_alias_override_is_honored" {
  command = plan

  variables {
    kms_alias_override = "alias/tfstate-custom"
  }

  assert {
    condition     = output.kms_alias_name == "alias/tfstate-custom"
    error_message = "kms_alias_override must flow into the component's kms_alias_name output."
  }
}

run "rejects_invalid_aft_mgmt_account_id" {
  command = plan

  variables {
    aft_mgmt_account_id = "not-a-number"
  }

  expect_failures = [
    var.aft_mgmt_account_id,
  ]
}
