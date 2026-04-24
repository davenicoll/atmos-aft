# Verifies the set_delegated_admin_account_id count-gate: null (default) →
# no aws_securityhub_organization_admin_account resource; 12-digit ID →
# exactly one. The ID must be a string (the audit caught a boolean `true`
# which would have failed plan type-check).

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "security-hub"
}

run "default_does_not_register_delegated_admin" {
  command = plan

  assert {
    condition     = length(aws_securityhub_organization_admin_account.this) == 0
    error_message = "With set_delegated_admin_account_id=null (default), the delegated-admin resource must NOT be declared — only the ct-mgmt stack should register the admin."
  }
}

run "non_null_account_id_registers_delegated_admin" {
  command = plan

  variables {
    set_delegated_admin_account_id = "123456789012"
  }

  assert {
    condition     = length(aws_securityhub_organization_admin_account.this) == 1
    error_message = "With a 12-digit account ID, exactly one delegated-admin resource must be declared."
  }

  assert {
    condition     = aws_securityhub_organization_admin_account.this[0].admin_account_id == "123456789012"
    error_message = "admin_account_id must match the variable value."
  }
}

run "aggregator_default_off" {
  command = plan

  assert {
    condition     = var.finding_aggregator_enabled == false
    error_message = "finding_aggregator_enabled must default to false — only the delegated-admin stack enables it (one aggregator per org)."
  }
}
