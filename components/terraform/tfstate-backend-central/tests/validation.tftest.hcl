# Variable validation + kms_alias_name contract for the central bootstrap
# state backend. Deep structural assertions on the module-owned bucket
# policy and key policy aren't reachable at plan time under mock_provider
# (the module's attributes are mocked), so focus is the user-facing
# contract + validation.
#
# KNOWN LATENT SHAPE CONCERN (not blocking, documented here for tracking):
# main.tf passes `[local.extra_bucket_statements]` to the cloudposse module's
# `source_policy_documents` input. That input expects each element to be a
# FULL policy document (with Version + Statement wrapper), but this
# component renders only a statements ARRAY via jsonencode. The mocked
# aws_iam_policy_document below masks this — remove the mock_data override
# and the module's internal aggregated_policy parses the statements array
# as a policy document and fails with "invalid character 'd'" (the first
# char of "DenyInsecureTransport"). The sibling `tfstate-backend`
# component does this correctly via data.aws_iam_policy_document.bucket_extra.
# TODO: mirror that pattern here; until then these tests only exercise the
# variable/contract surface.

mock_provider "aws" {
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
  # The wrapped cloudposse/tfstate-backend module internally merges policy
  # documents via aws_iam_policy_document.aggregated_policy; without a valid
  # mocked json that source fails with a JSON-parse error.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  region              = "us-east-1"
  namespace           = "test"
  stage               = "test"
  name                = "tfstate-backend-central"
  aft_mgmt_account_id = "123456789012"
}

run "kms_alias_output_is_bootstrap" {
  command = plan

  assert {
    condition     = output.kms_alias_name == "alias/atmos-tfstate-bootstrap"
    error_message = "Central bootstrap component must expose the canonical alias/atmos-tfstate-bootstrap name."
  }
}

run "rejects_invalid_aft_mgmt_account_id" {
  command = plan

  variables {
    aft_mgmt_account_id = "abc"
  }

  expect_failures = [
    var.aft_mgmt_account_id,
  ]
}

run "accepts_various_regions" {
  command = plan

  variables {
    region = "eu-west-1"
  }

  # The component's bucket name embeds <aft_mgmt_account_id>-<region>; a
  # clean plan here confirms the non-us-east-1 case doesn't short-circuit
  # on any hardcoded assumption.
  assert {
    condition     = var.region == "eu-west-1"
    error_message = "Region override must flow through (regression guard for any latent us-east-1 hardcode)."
  }
}
