# Verifies the cloudposse/sso account-assignments wrapper. The submodule
# reads three data sources at plan time:
#   - aws_ssoadmin_instances → instance_arn + identity_store_id
#   - aws_identitystore_group → resolves GROUP principal_name → id
#   - aws_identitystore_user  → resolves USER  principal_name → id
# All are mocked. The wrapper for_each-keys assignments by
# "<account>-<P>-<principal_name>-<permission_set_name>" so cardinality
# tracks var.account_assignments 1-for-1.

mock_provider "aws" {
  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns               = ["arn:aws:sso:::instance/ssoins-7777777777777777"]
      identity_store_ids = ["d-1234567890"]
    }
  }
  mock_data "aws_identitystore_group" {
    defaults = {
      group_id = "00000000-0000-0000-0000-000000000001"
      id       = "00000000-0000-0000-0000-000000000001"
    }
  }
  mock_data "aws_identitystore_user" {
    defaults = {
      user_id = "00000000-0000-0000-0000-000000000002"
      id      = "00000000-0000-0000-0000-000000000002"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "identity-center-assignments"
}

run "empty_list_creates_zero_assignments" {
  command = plan

  variables {
    account_assignments = []
  }

  assert {
    condition     = length(module.assignments.assignments) == 0
    error_message = "Empty var.account_assignments must produce zero account_assignment resources."
  }

  assert {
    condition     = output.assignment_count == 0
    error_message = "assignment_count output must be zero for an empty input."
  }
}

run "single_group_assignment_renders_one_resource" {
  command = plan

  variables {
    account_assignments = [
      {
        account             = "111111111111"
        permission_set_name = "AdministratorAccess"
        permission_set_arn  = "arn:aws:sso:::permissionSet/ssoins-7777777777777777/ps-aaaaaaaaaaaaaaaa"
        principal_name      = "AWS-Admins"
        principal_type      = "GROUP"
      },
    ]
  }

  assert {
    condition     = length(module.assignments.assignments) == 1
    error_message = "One assignment input must produce exactly one resource."
  }

  assert {
    condition     = output.assignment_count == 1
    error_message = "assignment_count must equal length(var.account_assignments)."
  }
}

run "multi_assignment_cardinality_matches" {
  command = plan

  variables {
    account_assignments = [
      {
        account             = "111111111111"
        permission_set_name = "AdministratorAccess"
        permission_set_arn  = "arn:aws:sso:::permissionSet/ssoins-7777777777777777/ps-aaaaaaaaaaaaaaaa"
        principal_name      = "AWS-Admins"
        principal_type      = "GROUP"
      },
      {
        account             = "222222222222"
        permission_set_name = "ReadOnlyAccess"
        permission_set_arn  = "arn:aws:sso:::permissionSet/ssoins-7777777777777777/ps-bbbbbbbbbbbbbbbb"
        principal_name      = "AWS-Readers"
        principal_type      = "GROUP"
      },
      {
        account             = "111111111111"
        permission_set_name = "AdministratorAccess"
        permission_set_arn  = "arn:aws:sso:::permissionSet/ssoins-7777777777777777/ps-aaaaaaaaaaaaaaaa"
        principal_name      = "alice@example.com"
        principal_type      = "USER"
      },
    ]
  }

  assert {
    condition     = length(module.assignments.assignments) == 3
    error_message = "Three assignment inputs must produce three resources."
  }

  assert {
    condition     = output.assignment_count == 3
    error_message = "assignment_count must reflect var.account_assignments length."
  }
}

run "principal_type_routes_user_vs_group" {
  command = plan

  variables {
    account_assignments = [
      {
        account             = "111111111111"
        permission_set_name = "Admin"
        permission_set_arn  = "arn:aws:sso:::permissionSet/ssoins-7777777777777777/ps-aaaaaaaaaaaaaaaa"
        principal_name      = "alice@example.com"
        principal_type      = "USER"
      },
    ]
  }

  # The wrapper conditional dispatches USER → identitystore_user, GROUP → identitystore_group.
  # We assert principal_type makes it onto the resource shape.
  assert {
    condition = alltrue([
      for a in module.assignments.assignments : a.principal_type == "USER"
    ])
    error_message = "Single USER assignment must render principal_type='USER' on the resource."
  }
}
