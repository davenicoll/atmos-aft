# Verifies the `skip_on_ct_managed_account` count-gate on the CIS-1.2
# submodule wrapper. Plan-only — no AWS credentials needed.

mock_provider "aws" {
  # The submodule looks up a region map by `data.aws_region.current.name`;
  # the mock_provider default is a random string, which breaks the lookup.
  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }
}

variables {
  region                 = "us-east-1"
  namespace              = "test"
  stage                  = "test"
  name                   = "aws-config-rules"
  support_policy_arn     = "arn:aws:iam::aws:policy/AWSSupportAccess"
  cloudtrail_bucket_name = "test-trail-bucket"
}

run "default_skips_on_ct_managed_account" {
  command = plan

  assert {
    condition     = length(module.cis_rules) == 0
    error_message = "With skip_on_ct_managed_account=true (default), module.cis_rules must not be instantiated — the CIS-1.2 submodule would collide with CT's configuration recorder."
  }
}

run "opt_in_creates_module" {
  command = plan

  variables {
    skip_on_ct_managed_account = false
  }

  assert {
    condition     = length(module.cis_rules) == 1
    error_message = "With skip_on_ct_managed_account=false, module.cis_rules must be instantiated."
  }
}
