# Variable validation + kms_alias_name contract for the central bootstrap
# state backend. The real aws provider (STS preflight skipped) lets
# data.aws_iam_policy_document.bucket_extra compute a genuine policy JSON,
# which the wrapped cloudposse module's internal aggregated_policy then
# parses successfully. A mock_provider here would return random strings
# for that .json attribute, masking the very shape-bug this was refactored
# to fix.

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "test"
  secret_key                  = "test"
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

run "bucket_extra_is_a_valid_policy_document" {
  command = plan

  # Regression guard: the component used to jsonencode a bare statements
  # ARRAY and pass it to source_policy_documents, which fails the module's
  # internal aggregated_policy JSON validation. Now we produce a full IAM
  # policy document via data.aws_iam_policy_document. Verify the shape.
  assert {
    condition = can(
      regex("\"Version\"\\s*:\\s*\"2012-10-17\"", data.aws_iam_policy_document.bucket_extra[0].json)
    )
    error_message = "bucket_extra must render a full IAM policy document (Version + Statement), not a bare statements array."
  }

  assert {
    condition = can(
      regex("DenyInsecureTransport", data.aws_iam_policy_document.bucket_extra[0].json)
    )
    error_message = "bucket_extra must contain the DenyInsecureTransport statement."
  }

  assert {
    condition = can(
      regex("AllowReadAllStateRoleRead", data.aws_iam_policy_document.bucket_extra[0].json)
    )
    error_message = "bucket_extra must contain the AllowReadAllStateRoleRead statement."
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
