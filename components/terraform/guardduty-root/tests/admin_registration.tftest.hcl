# Phase 1 - registers the audit account as the GuardDuty delegated admin
# from CT-mgmt. Plan-only; verifies count-gate, value propagation, and the
# 12-digit precondition on var.delegated_admin_account_id.

mock_provider "aws" {}

variables {
  region                     = "us-east-1"
  namespace                  = "test"
  stage                      = "test"
  name                       = "guardduty-root"
  delegated_admin_account_id = "111111111111"
}

run "default_registers_delegated_admin" {
  command = plan

  assert {
    condition     = length(aws_guardduty_organization_admin_account.this) == 1
    error_message = "With enabled=true (default), exactly one aws_guardduty_organization_admin_account must be declared."
  }

  assert {
    condition     = aws_guardduty_organization_admin_account.this[0].admin_account_id == "111111111111"
    error_message = "admin_account_id must echo var.delegated_admin_account_id."
  }
}

run "disabled_module_creates_nothing" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = length(aws_guardduty_organization_admin_account.this) == 0
    error_message = "With enabled=false, the delegated-admin resource must not be declared."
  }
}

run "rejects_short_account_id" {
  command = plan

  variables {
    delegated_admin_account_id = "12345"
  }

  expect_failures = [
    aws_guardduty_organization_admin_account.this,
  ]
}

run "rejects_non_numeric_account_id" {
  command = plan

  variables {
    delegated_admin_account_id = "abcdefghijkl"
  }

  expect_failures = [
    aws_guardduty_organization_admin_account.this,
  ]
}
