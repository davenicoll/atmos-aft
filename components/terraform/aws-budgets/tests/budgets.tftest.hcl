# Verifies the wrapped cloudposse/budgets/aws module instantiates one
# aws_budgets_budget per entry in var.budgets, that defaults flow through
# (limit_unit, time_unit, budget_type), and that the empty-budgets default
# yields zero budget resources.
#
# Note: the inner module's `budgets` output is `aws_budgets_budget.default[*]`
# which, because `default` is keyed via for_each, surfaces as a list with a
# single map element: `[{"0" = <budget>, "1" = <budget>, ...}]`. To count
# budgets we therefore use `length(module.budgets.budgets[0])` and to read
# attributes we index by the stringified for_each key, e.g.
# `module.budgets.budgets[0]["0"].budget_type`.

mock_provider "aws" {
  # The wrapped module unconditionally evaluates a data.aws_caller_identity
  # and a data.aws_iam_policy_document (via .json) — provide a stub policy
  # JSON so any json-decoding inside transitive modules does not blow up.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aws-budgets"
}

run "empty_budgets_default_creates_no_budget_resources" {
  command = plan

  # var.budgets defaults to []. The inner module's
  # `for_each = local.budgets` over an empty map yields zero
  # aws_budgets_budget instances. The splat-over-for_each shape means
  # `budgets[0]` is the (empty) map; its length is the budget count.
  assert {
    condition     = length(module.budgets.budgets[0]) == 0
    error_message = "Default var.budgets=[] must surface zero budgets in module.budgets.budgets[0]."
  }

  # Echo on the wrapper output too — try() should yield [] when the inner
  # module does not expose budget_names.
  assert {
    condition     = length(output.budget_names) == 0
    error_message = "budget_names output must be empty list when no budgets configured."
  }
}

run "single_monthly_budget_creates_one_resource" {
  command = plan

  variables {
    budgets = [
      {
        name         = "monthly-cost-cap"
        budget_type  = "COST"
        limit_amount = "1000"
        limit_unit   = "USD"
        time_unit    = "MONTHLY"
      },
    ]
  }

  assert {
    condition     = length(module.budgets.budgets[0]) == 1
    error_message = "One entry in var.budgets must surface exactly one budget in module.budgets.budgets[0]."
  }

  # for_each is keyed by list-index; the first (and only) entry is "0".
  assert {
    condition     = module.budgets.budgets[0]["0"].budget_type == "COST"
    error_message = "budget_type must propagate from var.budgets[0] into the inner aws_budgets_budget."
  }

  assert {
    condition     = module.budgets.budgets[0]["0"].limit_amount == "1000"
    error_message = "limit_amount must propagate from var.budgets[0]."
  }

  assert {
    condition     = module.budgets.budgets[0]["0"].time_unit == "MONTHLY"
    error_message = "time_unit must propagate from var.budgets[0]."
  }

  # The wrapper composes the budget name as `<id>-<each.value.name>`; the
  # full id depends on null-label inputs, but the suffix is stable.
  assert {
    condition     = endswith(module.budgets.budgets[0]["0"].name, "monthly-cost-cap")
    error_message = "Budget name must end with the name field from var.budgets[0]."
  }
}

run "multiple_budgets_create_multiple_resources" {
  command = plan

  variables {
    budgets = [
      {
        name         = "monthly-cost"
        budget_type  = "COST"
        limit_amount = "1000"
        limit_unit   = "USD"
        time_unit    = "MONTHLY"
      },
      {
        name         = "quarterly-usage"
        budget_type  = "USAGE"
        limit_amount = "500"
        limit_unit   = "GB"
        time_unit    = "QUARTERLY"
      },
    ]
  }

  assert {
    condition     = length(module.budgets.budgets[0]) == 2
    error_message = "Two entries in var.budgets must surface exactly two budgets."
  }

  # Either ordering is fine — assert both budget_types are represented.
  assert {
    condition = alltrue([
      contains([for k, b in module.budgets.budgets[0] : b.budget_type], "COST"),
      contains([for k, b in module.budgets.budgets[0] : b.budget_type], "USAGE"),
    ])
    error_message = "Both COST and USAGE budget_types must be present across the two budgets."
  }
}

run "notification_block_propagates_to_inner_resource" {
  command = plan

  variables {
    budgets = [
      {
        name         = "monthly-cost"
        budget_type  = "COST"
        limit_amount = "1000"
        limit_unit   = "USD"
        time_unit    = "MONTHLY"
        notification = [
          {
            comparison_operator        = "GREATER_THAN"
            threshold                  = 80
            threshold_type             = "PERCENTAGE"
            notification_type          = "ACTUAL"
            subscriber_email_addresses = ["alerts@example.com"]
          },
        ]
      },
    ]
  }

  # The wrapped module's `notification` dynamic block keys off
  # lookup(value, "notification", null); supplying notification[0] should
  # surface one notification block on the inner aws_budgets_budget.
  # `notification` is rendered as a set-of-object so we use one() to peek
  # at the single element rather than indexing.
  assert {
    condition     = length(module.budgets.budgets[0]["0"].notification) == 1
    error_message = "Supplying one notification entry must emit exactly one notification block."
  }

  assert {
    condition     = one(module.budgets.budgets[0]["0"].notification).threshold == 80
    error_message = "notification.threshold must propagate as 80 (percentage)."
  }

  assert {
    condition     = one(module.budgets.budgets[0]["0"].notification).notification_type == "ACTUAL"
    error_message = "notification.notification_type must propagate as ACTUAL."
  }
}

run "wrapper_outputs_default_to_empty_list_via_try" {
  command = plan

  variables {
    budgets = []
  }

  # The component-level outputs wrap module.budgets.budget_names/_ids in
  # try(...) defaulting to []. The inner module exposes `budgets` (resource
  # list) but not `budget_names` — so the try() degrades cleanly. This is
  # the contract: consumers see [] not an error.
  assert {
    condition     = length(output.budget_names) == 0
    error_message = "budget_names must default to [] when inner module does not expose that output."
  }

  assert {
    condition     = length(output.budget_ids) == 0
    error_message = "budget_ids must default to [] when inner module does not expose that output."
  }
}
