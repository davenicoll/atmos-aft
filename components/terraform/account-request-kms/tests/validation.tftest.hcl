# Variable validation + default-description contract.

mock_provider "aws" {}

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "aft-request-kms"
  alias     = "alias/aft-request"
}

run "default_description_sentinel" {
  command = plan

  assert {
    condition     = var.description == "Atmos-AFT management-plane CMK"
    error_message = "Default CMK description must be the atmos-aft sentinel."
  }
}

run "default_deletion_window_30_days" {
  command = plan

  assert {
    condition     = var.deletion_window_in_days == 30
    error_message = "Default deletion_window_in_days must be 30 (AWS max) — lower values reduce recovery time on accidental delete."
  }
}

run "rejects_alias_without_alias_prefix" {
  command = plan

  variables {
    alias = "my-key"
  }

  expect_failures = [
    var.alias,
  ]
}

run "accepts_valid_alias" {
  command = plan

  variables {
    alias = "alias/atmos-aft/account-request"
  }

  assert {
    condition     = var.alias == "alias/atmos-aft/account-request"
    error_message = "Valid alias with nested slashes must be accepted."
  }
}
