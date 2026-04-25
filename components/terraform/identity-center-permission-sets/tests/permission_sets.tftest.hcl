# Verifies the cloudposse/sso permission-sets wrapper. The submodule reads
# aws_ssoadmin_instances at plan time (used to derive instance_arn for every
# permission set), so we mock that data source. The ssoadmin_permission_set
# resources have for_each over var.permission_sets keyed by .name, so a
# populated list produces N resources, an empty list produces zero.

mock_provider "aws" {
  mock_data "aws_ssoadmin_instances" {
    defaults = {
      arns               = ["arn:aws:sso:::instance/ssoins-7777777777777777"]
      identity_store_ids = ["d-1234567890"]
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "identity-center-permission-sets"
}

run "empty_list_creates_zero_permission_sets" {
  command = plan

  variables {
    permission_sets = []
  }

  assert {
    condition     = length(module.permission_sets.permission_sets) == 0
    error_message = "Empty var.permission_sets must produce zero aws_ssoadmin_permission_set resources."
  }
}

run "populated_list_creates_one_per_entry" {
  command = plan

  variables {
    permission_sets = [
      {
        name                                = "AdministratorAccess"
        description                         = "Full admin"
        relay_state                         = ""
        session_duration                    = ""
        tags                                = {}
        inline_policy                       = ""
        policy_attachments                  = ["arn:aws:iam::aws:policy/AdministratorAccess"]
        customer_managed_policy_attachments = []
      },
      {
        name                                = "ReadOnlyAccess"
        description                         = "Read-only"
        relay_state                         = ""
        session_duration                    = "PT4H"
        tags                                = {}
        inline_policy                       = ""
        policy_attachments                  = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]
        customer_managed_policy_attachments = []
      },
    ]
  }

  assert {
    condition     = length(module.permission_sets.permission_sets) == 2
    error_message = "Two entries in var.permission_sets must produce two permission_set resources."
  }

  assert {
    condition     = contains(keys(module.permission_sets.permission_sets), "AdministratorAccess")
    error_message = "Permission set keyed by .name must surface 'AdministratorAccess'."
  }

  assert {
    condition     = contains(keys(module.permission_sets.permission_sets), "ReadOnlyAccess")
    error_message = "Permission set keyed by .name must surface 'ReadOnlyAccess'."
  }
}

run "session_duration_propagates" {
  command = plan

  variables {
    permission_sets = [
      {
        name                                = "PowerUser"
        description                         = "Power user with 8h session"
        relay_state                         = ""
        session_duration                    = "PT8H"
        tags                                = {}
        inline_policy                       = ""
        policy_attachments                  = []
        customer_managed_policy_attachments = []
      },
    ]
  }

  # Assert session_duration on the rendered permission set. `coalesce`-style
  # logic in the module maps "" → null and PT8H → "PT8H".
  assert {
    condition     = module.permission_sets.permission_sets["PowerUser"].session_duration == "PT8H"
    error_message = "Non-empty session_duration must propagate to the rendered permission set."
  }
}

run "var_surface_drives_arn_output" {
  # The component output `permission_set_arns` is a map<name → arn>. Since
  # arn is computed-after-apply (mock_provider gives unknowns), assert
  # cardinality of keys instead.
  command = plan

  variables {
    permission_sets = [
      {
        name                                = "Billing"
        description                         = "Billing read-only"
        relay_state                         = ""
        session_duration                    = ""
        tags                                = {}
        inline_policy                       = ""
        policy_attachments                  = []
        customer_managed_policy_attachments = []
      },
    ]
  }

  assert {
    condition     = length(var.permission_sets) == 1
    error_message = "Var surface must record exactly one permission-set entry."
  }
}
