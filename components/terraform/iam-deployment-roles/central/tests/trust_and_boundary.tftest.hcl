# Verifies the central role topology: AtmosCentralDeploymentRole trusts
# OIDC for main/deploy-environments only; AtmosPlanOnlyRole trusts OIDC
# for pull_request only; AtmosReadAllStateRole has a permissions boundary
# with an explicit Deny on write actions. The provider override with
# skip flags keeps aws_iam_policy_document.json real-computed so the
# assertions examine the actual policy output; override_data stubs the
# one aws_caller_identity lookup.

provider "aws" {
  region                      = "us-east-1"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  access_key                  = "test"
  secret_key                  = "test"
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDAI23HX7LNZEXAMPLE"
  }
}

variables {
  region                   = "us-east-1"
  namespace                = "test"
  stage                    = "test"
  name                     = "iam-deployment-roles-central"
  github_org               = "acme"
  github_repo              = "atmos-aft"
  github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}

run "central_trust_pins_deploy_environments_only" {
  command = plan

  # The deploy sub-claim list is built in locals from github_org/repo.
  # Assertion: the trust policy allows main + the three deploy
  # environments (aft-mgmt, vended, core) and NOT pull_request.
  assert {
    condition = can(
      regex("repo:acme/atmos-aft:ref:refs/heads/main", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must allow the main branch sub claim."
  }

  assert {
    condition = can(
      regex("repo:acme/atmos-aft:environment:aft-mgmt", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must allow environment:aft-mgmt."
  }

  assert {
    condition = can(
      regex("repo:acme/atmos-aft:environment:vended", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must allow environment:vended."
  }

  assert {
    condition = can(
      regex("repo:acme/atmos-aft:environment:core", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must allow environment:core."
  }

  assert {
    condition = !can(
      regex("repo:acme/atmos-aft:pull_request", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must NOT allow pull_request - that flow uses AtmosPlanOnlyRole."
  }

  assert {
    condition = can(
      regex("token.actions.githubusercontent.com:aud", data.aws_iam_policy_document.central_trust.json)
    )
    error_message = "central_trust must pin the OIDC audience."
  }
}

run "plan_only_trust_pins_pull_request_only" {
  command = plan

  assert {
    condition = can(
      regex("repo:acme/atmos-aft:pull_request", data.aws_iam_policy_document.plan_only_trust.json)
    )
    error_message = "plan_only_trust must allow pull_request sub."
  }

  assert {
    condition = !can(
      regex("refs/heads/main", data.aws_iam_policy_document.plan_only_trust.json)
    )
    error_message = "plan_only_trust must NOT allow main - that flow is AtmosCentralDeploymentRole."
  }
}

# Note: central_assume_targets content isn't asserted here because the
# policy references aws_iam_role.read_all_state[0].arn, which is computed
# and unknown at plan time. Neither override_resource nor override_during
# currently propagate into iam_policy_document rendering. If that changes,
# re-add assertions for AtmosDeploymentRole / AWSControlTowerExecution /
# OrganizationAccountAccessRole targets here.

run "read_all_trust_uses_caller_identity_account" {
  command = plan

  # Trust is same-account only (the overridden caller_identity.account_id).
  assert {
    condition = can(
      regex("arn:aws:iam::123456789012:role/AtmosCentralDeploymentRole", data.aws_iam_policy_document.read_all_trust.json)
    )
    error_message = "read_all_trust must reference AtmosCentralDeploymentRole in the overridden caller account (123456789012)."
  }
}

run "read_all_boundary_denies_writes" {
  command = plan

  assert {
    condition = can(
      regex("\"Deny\"", data.aws_iam_policy_document.read_all_boundary.json)
    )
    error_message = "read_all_boundary must have a Deny statement (explicit write-action block)."
  }

  assert {
    condition = alltrue([
      can(regex("\"s3:Put\\*\"", data.aws_iam_policy_document.read_all_boundary.json)),
      can(regex("\"s3:Delete\\*\"", data.aws_iam_policy_document.read_all_boundary.json)),
      can(regex("\"kms:Encrypt\\*\"", data.aws_iam_policy_document.read_all_boundary.json)),
      can(regex("\"kms:GenerateDataKey\\*\"", data.aws_iam_policy_document.read_all_boundary.json)),
    ])
    error_message = "read_all_boundary must Deny s3:Put*, s3:Delete*, kms:Encrypt*, kms:GenerateDataKey*."
  }
}

run "rejects_invalid_oidc_provider_arn" {
  command = plan

  variables {
    github_oidc_provider_arn = "not-an-arn"
  }

  expect_failures = [
    var.github_oidc_provider_arn,
  ]
}
