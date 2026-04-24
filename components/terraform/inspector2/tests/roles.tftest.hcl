# Verifies the three role shapes — management | delegated | member — each
# instantiate the correct subset of aws_inspector2_* resources and nothing
# else. Also covers variable validation on `role`.

mock_provider "aws" {}

variables {
  region = "us-east-1"
}

run "management_sets_delegated_admin_only" {
  command = plan

  variables {
    role                       = "management"
    delegated_admin_account_id = "111111111111"
  }

  assert {
    condition     = length(aws_inspector2_delegated_admin_account.this) == 1
    error_message = "role=management must declare aws_inspector2_delegated_admin_account."
  }

  assert {
    condition     = length(aws_inspector2_organization_configuration.this) == 0
    error_message = "role=management must NOT declare aws_inspector2_organization_configuration."
  }

  assert {
    condition     = length(aws_inspector2_enabler.this) == 0
    error_message = "role=management must NOT declare aws_inspector2_enabler."
  }

  assert {
    condition     = length(aws_inspector2_member_association.this) == 0
    error_message = "role=management must NOT declare aws_inspector2_member_association."
  }

  assert {
    condition     = aws_inspector2_delegated_admin_account.this[0].account_id == "111111111111"
    error_message = "delegated admin account_id must match var.delegated_admin_account_id."
  }
}

run "delegated_configures_org_and_enabler" {
  command = plan

  variables {
    role                = "delegated"
    enabler_account_ids = ["222222222222", "333333333333"]
  }

  assert {
    condition     = length(aws_inspector2_delegated_admin_account.this) == 0
    error_message = "role=delegated must NOT declare aws_inspector2_delegated_admin_account."
  }

  assert {
    condition     = length(aws_inspector2_organization_configuration.this) == 1
    error_message = "role=delegated must declare aws_inspector2_organization_configuration."
  }

  assert {
    condition     = length(aws_inspector2_enabler.this) == 1
    error_message = "role=delegated must declare aws_inspector2_enabler."
  }

  # All four auto_enable defaults should be true
  assert {
    condition = alltrue([
      aws_inspector2_organization_configuration.this[0].auto_enable[0].ec2,
      aws_inspector2_organization_configuration.this[0].auto_enable[0].ecr,
      aws_inspector2_organization_configuration.this[0].auto_enable[0].lambda,
      aws_inspector2_organization_configuration.this[0].auto_enable[0].lambda_code,
    ])
    error_message = "All four auto_enable defaults must be true."
  }
}

run "member_associates_only" {
  command = plan

  variables {
    role              = "member"
    member_account_id = "444444444444"
  }

  assert {
    condition     = length(aws_inspector2_member_association.this) == 1
    error_message = "role=member must declare aws_inspector2_member_association."
  }

  assert {
    condition     = length(aws_inspector2_delegated_admin_account.this) == 0
    error_message = "role=member must not declare delegated_admin_account."
  }

  assert {
    condition     = length(aws_inspector2_organization_configuration.this) == 0
    error_message = "role=member must not declare org configuration."
  }

  assert {
    condition     = length(aws_inspector2_enabler.this) == 0
    error_message = "role=member must not declare enabler."
  }
}

run "rejects_invalid_role" {
  command = plan

  variables {
    role = "bogus"
  }

  expect_failures = [
    var.role,
  ]
}
