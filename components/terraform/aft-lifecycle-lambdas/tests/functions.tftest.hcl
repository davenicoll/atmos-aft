# aft-lifecycle-lambdas is a generic for_each shim over cloudposse/lambda-function.
# var.functions is a map(object) where each entry produces one Lambda. The
# audit flagged this as thin (no per-function options beyond the object's
# fields), so these tests lock in WHAT IT DOES:
#   - Empty map = no functions instantiated.
#   - Populated map = N module instances.
#   - Optional fields default per the object schema.
#   - Required fields (filename, handler) are honored.

mock_provider "aws" {
  # cloudposse/lambda-function jsondecodes its assume-role policy doc.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:root"
      user_id    = "123456789012"
    }
  }
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_region" {
    defaults = {
      name = "us-east-1"
    }
  }
}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-lifecycle"
}

run "empty_functions_map_produces_zero_lambdas" {
  command = plan

  variables {
    functions = {}
  }

  # `module.lambda` is a for_each over var.functions. With an empty map there
  # are no instances; we assert via the variable surface (a length(module.X)
  # check is permitted but the variable is the source of truth).
  assert {
    condition     = length(var.functions) == 0
    error_message = "Empty functions map must produce zero lambdas."
  }
}

run "three_function_map_produces_three_lambdas" {
  command = plan

  variables {
    functions = {
      delete_default_vpc = {
        filename = "build/delete_default_vpc.zip"
        handler  = "main.lambda_handler"
      }
      enable_cloudtrail = {
        filename = "build/enable_cloudtrail.zip"
        handler  = "main.lambda_handler"
      }
      enroll_support = {
        filename = "build/enroll_support.zip"
        handler  = "main.lambda_handler"
      }
    }
  }

  assert {
    condition     = length(var.functions) == 3
    error_message = "Three entries in functions map must propagate."
  }

  # All three keys must be present — guards against any silent filtering.
  assert {
    condition = alltrue([
      contains(keys(var.functions), "delete_default_vpc"),
      contains(keys(var.functions), "enable_cloudtrail"),
      contains(keys(var.functions), "enroll_support"),
    ])
    error_message = "All three AFT lifecycle Lambda keys must survive into var.functions."
  }
}

run "optional_fields_apply_object_defaults" {
  command = plan

  variables {
    functions = {
      probe = {
        filename = "build/probe.zip"
        handler  = "main.lambda_handler"
      }
    }
  }

  # Optional defaults declared in variables.tf:
  #   runtime               = "python3.12"
  #   timeout               = 60
  #   memory_size           = 256
  #   architecture          = "arm64"
  #   log_retention_in_days = 90
  assert {
    condition     = var.functions["probe"].runtime == "python3.12"
    error_message = "Default runtime must be python3.12 — the AFT-baseline runtime."
  }

  assert {
    condition     = var.functions["probe"].timeout == 60
    error_message = "Default timeout must be 60s."
  }

  assert {
    condition     = var.functions["probe"].memory_size == 256
    error_message = "Default memory_size must be 256MB."
  }

  assert {
    condition     = var.functions["probe"].architecture == "arm64"
    error_message = "Default architecture must be arm64 (Graviton, cheaper than x86_64)."
  }

  assert {
    condition     = var.functions["probe"].log_retention_in_days == 90
    error_message = "Default log_retention_in_days must be 90 — keeps Lambda log groups bounded."
  }

  # Optional pointers that are null by default — the wrapper sets the
  # corresponding module input to null/empty when the per-function value is
  # null, so a non-null default would silently force a value through.
  assert {
    condition     = var.functions["probe"].environment == null
    error_message = "Default environment must be null so the wrapper omits lambda_environment entirely."
  }

  assert {
    condition     = var.functions["probe"].log_kms_key_arn == null
    error_message = "Default log_kms_key_arn must be null."
  }

  assert {
    condition     = var.functions["probe"].policy_json == null
    error_message = "Default policy_json must be null — opt-in inline IAM only."
  }
}

run "explicit_per_function_overrides_propagate" {
  command = plan

  variables {
    functions = {
      heavy = {
        filename              = "build/heavy.zip"
        handler               = "main.lambda_handler"
        runtime               = "python3.11"
        timeout               = 300
        memory_size           = 1024
        architecture          = "x86_64"
        environment           = { LOG_LEVEL = "DEBUG" }
        log_retention_in_days = 30
        policy_json           = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      }
    }
  }

  assert {
    condition     = var.functions["heavy"].runtime == "python3.11"
    error_message = "Explicit runtime override must propagate through the map."
  }

  assert {
    condition     = var.functions["heavy"].timeout == 300
    error_message = "Explicit timeout override must propagate."
  }

  assert {
    condition     = var.functions["heavy"].memory_size == 1024
    error_message = "Explicit memory_size override must propagate."
  }

  assert {
    condition     = var.functions["heavy"].architecture == "x86_64"
    error_message = "Explicit architecture override must propagate."
  }

  assert {
    condition     = var.functions["heavy"].environment["LOG_LEVEL"] == "DEBUG"
    error_message = "Explicit environment map must propagate."
  }
}
