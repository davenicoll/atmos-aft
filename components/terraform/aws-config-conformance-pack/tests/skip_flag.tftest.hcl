# Verifies the `skip_on_ct_managed_account` count-gate on the conformance-pack
# submodule wrapper. Same contract as aws-config-rules.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = {
      name   = "us-east-1"
      region = "us-east-1"
    }
  }
}

variables {
  region               = "us-east-1"
  namespace            = "test"
  stage                = "test"
  name                 = "aws-config-conformance-pack"
  conformance_pack_url = "https://raw.githubusercontent.com/awslabs/aws-config-rules/master/aws-config-conformance-packs/Operational-Best-Practices-for-CIS.yaml"
}

run "default_skips_on_ct_managed_account" {
  command = plan

  assert {
    condition     = length(module.pack) == 0
    error_message = "With skip_on_ct_managed_account=true (default), module.pack must not be instantiated."
  }
}

run "opt_in_creates_module" {
  command = plan

  variables {
    skip_on_ct_managed_account = false
  }

  assert {
    condition     = length(module.pack) == 1
    error_message = "With skip_on_ct_managed_account=false, module.pack must be instantiated."
  }
}
