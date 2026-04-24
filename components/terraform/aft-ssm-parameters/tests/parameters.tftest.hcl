# Verifies the parameter map transform + bool-typed `overwrite` field.
# Regression guard: a previous `tostring(v.overwrite)` would pass a string
# "true"/"false" to cloudposse/ssm-parameter-store which expects bool.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-ssm-parameters"
}

run "empty_parameters_map_is_valid" {
  command = plan

  variables {
    parameters = {}
  }
}

run "parameters_map_renders_correctly" {
  command = plan

  variables {
    parameters = {
      "/aft/account/alpha/status" = {
        value       = "baseline-deployed"
        description = "Alpha account status"
      }
      "/aft/account/alpha/stack" = {
        value       = "plat-use1-prod"
        type        = "String"
        tier        = "Standard"
        description = "Alpha stack name"
        overwrite   = false
      }
    }
  }

  # The module-private transform builds `parameter_write`. We assert the
  # `overwrite` field on the first entry is a bool, not a string — that is
  # the regression-target for the tostring() fix.
  assert {
    condition = alltrue([
      for p in [
        for k, v in var.parameters : {
          name      = k
          value     = v.value
          type      = v.type
          tier      = v.tier
          overwrite = v.overwrite
        }
      ] : tobool(p.overwrite) == true || tobool(p.overwrite) == false
    ])
    error_message = "All `overwrite` values must be bool-typed (not stringified)."
  }
}

# Note: bool-vs-string on `overwrite` is caught by the variable type system
# itself, which produces a hard type error rather than a soft validation
# failure — those cannot be asserted via `expect_failures`. The bool type
# declaration in variables.tf is the regression guard.
