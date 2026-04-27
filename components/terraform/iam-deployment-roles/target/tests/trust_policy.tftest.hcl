# Verifies the AtmosDeploymentRole trust policy: ExternalId is required on
# the four CT-core account classes and omitted on vended; session-name
# StringLike is pinned to exactly {atmos-aft, atmos-aft-bootstrap} (not a
# broader `atmos-*` glob).
#
# Uses a test-local provider override (not mock_provider) because
# `aws_iam_policy_document` is pure-compute and the assertions read its
# `json` output. mock_provider returns random strings there, which then
# fail client-side JSON validation on aws_iam_role. The skip_* flags avoid
# STS preflight so no credentials are needed.

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "test"
  secret_key                  = "test"
}

provider "aws" {
  alias                       = "target"
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
  name                = "iam-deployment-roles-target"
  aft_mgmt_account_id = "123456789012"
  atmos_external_id   = "test-external-id-abcdef1234567890"
  target_role_arn     = ""
}

run "ct_mgmt_requires_external_id" {
  command = plan

  variables {
    account_class = "ct-mgmt"
  }

  assert {
    condition = can(
      regex("\"sts:ExternalId\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "ct-mgmt placement must include sts:ExternalId condition in the deployment trust policy."
  }
}

run "log_archive_requires_external_id" {
  command = plan

  variables {
    account_class = "log-archive"
  }

  assert {
    condition = can(
      regex("\"sts:ExternalId\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "log-archive placement must include sts:ExternalId condition in the deployment trust policy."
  }
}

run "vended_omits_external_id" {
  command = plan

  variables {
    account_class = "vended"
  }

  assert {
    condition = !can(
      regex("\"sts:ExternalId\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "vended placement must NOT include sts:ExternalId condition (the fresh account ID is the uniqueness signal)."
  }
}

run "session_name_pinned_to_exact_values" {
  command = plan

  variables {
    account_class = "vended"
  }

  # Both the Deployment and ReadOnly trust policies pin session-name explicitly
  # to the two atmos session names; a wildcard `atmos-*` glob is a finding.
  assert {
    condition = can(
      regex("\"AROA\\*:atmos-aft\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "deployment_trust must allow session-name 'atmos-aft' via StringLike aws:userid."
  }

  assert {
    condition = can(
      regex("\"AROA\\*:atmos-aft-bootstrap\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "deployment_trust must allow session-name 'atmos-aft-bootstrap' via StringLike aws:userid."
  }

  # And NO broader patterns.
  assert {
    condition = !can(
      regex("\"AROA\\*:atmos-\\*\"", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "deployment_trust must NOT allow the broader 'atmos-*' session-name glob - tighten to the exact session names."
  }
}

run "central_role_arn_derived_from_account_id" {
  command = plan

  variables {
    account_class = "vended"
  }

  assert {
    condition = can(
      regex("arn:aws:iam::123456789012:role/AtmosCentralDeploymentRole", data.aws_iam_policy_document.deployment_trust.json)
    )
    error_message = "deployment_trust Principal must include AtmosCentralDeploymentRole ARN built from var.aft_mgmt_account_id."
  }
}

run "rejects_invalid_account_class" {
  command = plan

  variables {
    account_class = "bogus"
  }

  expect_failures = [
    var.account_class,
  ]
}

run "rejects_invalid_aft_mgmt_account_id" {
  command = plan

  variables {
    account_class       = "vended"
    aft_mgmt_account_id = "not-a-number"
  }

  expect_failures = [
    var.aft_mgmt_account_id,
  ]
}

run "rejects_too_short_external_id" {
  command = plan

  variables {
    account_class     = "ct-mgmt"
    atmos_external_id = "short"
  }

  expect_failures = [
    var.atmos_external_id,
  ]
}

run "rejects_empty_external_id_on_ct_core_class" {
  command = plan

  # The variable validation accepts "" (for vended accounts that don't
  # need ExternalId). The lifecycle.precondition on aws_iam_role.deployment
  # enforces the cross-variable invariant: CT-core class + empty
  # ExternalId would render values=[""] in the trust statement, silently
  # locking the role out for everyone.
  variables {
    account_class     = "ct-mgmt"
    atmos_external_id = ""
  }

  expect_failures = [
    aws_iam_role.deployment,
  ]
}

run "vended_with_empty_external_id_is_allowed" {
  command = plan

  # Vended accounts intentionally don't require ExternalId (the freshly-
  # vended account ID is the uniqueness signal). Confirm the precondition
  # only fires for CT-core classes.
  variables {
    account_class     = "vended"
    atmos_external_id = ""
  }

  assert {
    condition     = var.atmos_external_id == ""
    error_message = "vended + empty external_id must be permitted."
  }
}
