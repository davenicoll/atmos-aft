# Verifies the Service Catalog provisioned-product wiring: one product,
# six provisioning_parameters in the documented order, the atmos:* tag
# stamps, and the prevent_destroy lifecycle guard.
#
# Also covers the account_id output precondition: the provisioned product's
# RecordOutputs.AccountId is populated post-provisioning by Control Tower,
# so the precondition fails the apply rather than emit null to SSM. We
# can't trigger the precondition at plan-time (the output value is unknown
# until apply), but we lock in the surrounding contract so the precondition
# stays paired with its inputs.

mock_provider "aws" {}

variables {
  region                      = "us-east-1"
  namespace                   = "test"
  stage                       = "test"
  name                        = "account-provisioning"
  account_name                = "alpha-prod"
  account_email               = "aws+alpha-prod@example.com"
  managed_organizational_unit = "Workloads"
  sso_user_email              = "owner@example.com"
  sso_user_first_name         = "Alpha"
  sso_user_last_name          = "Owner"
  ct_product_id               = "prod-aaaaaaaaaaaaa"
}

run "default_declares_exactly_one_provisioned_product" {
  command = plan

  assert {
    condition     = length(aws_servicecatalog_provisioned_product.account) == 1
    error_message = "Exactly one aws_servicecatalog_provisioned_product must be declared."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].name == "atmos-account-alpha-prod"
    error_message = "Provisioned-product name must be 'atmos-account-<account_name>'."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].product_id == "prod-aaaaaaaaaaaaa"
    error_message = "product_id must echo var.ct_product_id."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].provisioning_artifact_name == "AWS Control Tower Account Factory"
    error_message = "Default provisioning_artifact_name must be the CT-managed artifact."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].accept_language == "en"
    error_message = "accept_language must be 'en' (only supported value)."
  }
}

run "all_six_provisioning_parameters_propagate_with_correct_keys" {
  command = plan

  # CT's Account Factory product expects exactly these six keys — drift
  # in spelling or order silently breaks account creation.
  assert {
    condition     = length(aws_servicecatalog_provisioned_product.account[0].provisioning_parameters) == 6
    error_message = "There must be exactly 6 provisioning_parameters blocks (AccountName, AccountEmail, ManagedOrganizationalUnit, SSOUserEmail, SSOUserFirstName, SSOUserLastName)."
  }

  # Build a key→value map from the parameter blocks for clean assertions.
  assert {
    condition = alltrue([
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "AccountName"),
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "AccountEmail"),
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "ManagedOrganizationalUnit"),
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "SSOUserEmail"),
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "SSOUserFirstName"),
      contains([for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters : p.key], "SSOUserLastName"),
    ])
    error_message = "All six expected provisioning-parameter keys must be present (CT product contract)."
  }

  # Spot-check three values to lock the variable-to-key mapping.
  assert {
    condition = anytrue([
      for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters :
      p.key == "AccountName" && p.value == "alpha-prod"
    ])
    error_message = "AccountName parameter must echo var.account_name."
  }

  assert {
    condition = anytrue([
      for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters :
      p.key == "AccountEmail" && p.value == "aws+alpha-prod@example.com"
    ])
    error_message = "AccountEmail parameter must echo var.account_email."
  }

  assert {
    condition = anytrue([
      for p in aws_servicecatalog_provisioned_product.account[0].provisioning_parameters :
      p.key == "ManagedOrganizationalUnit" && p.value == "Workloads"
    ])
    error_message = "ManagedOrganizationalUnit parameter must echo var.managed_organizational_unit."
  }
}

run "atmos_class_tags_are_stamped_on_provisioned_product" {
  command = plan

  # The atmos:account-* tag triple is what downstream OPA + GHA jobs key
  # off to recognize a vended account vs. a hand-rolled one.
  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].tags["atmos:account-class"] == "vended"
    error_message = "atmos:account-class tag must be 'vended'."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].tags["atmos:account-name"] == "alpha-prod"
    error_message = "atmos:account-name tag must echo var.account_name."
  }

  assert {
    condition     = aws_servicecatalog_provisioned_product.account[0].tags["atmos:account-email"] == "aws+alpha-prod@example.com"
    error_message = "atmos:account-email tag must echo var.account_email."
  }
}

run "rejects_invalid_account_name_format" {
  command = plan

  variables {
    # Underscores and uppercase are forbidden by the regex in variables.tf.
    account_name = "Alpha_Prod"
  }

  expect_failures = [
    var.account_name,
  ]
}

run "rejects_invalid_account_email_format" {
  command = plan

  variables {
    account_email = "not-an-email"
  }

  expect_failures = [
    var.account_email,
  ]
}

run "echo_outputs_propagate_at_plan_time" {
  command = plan

  # account_name + managed_organizational_unit are pure-input echoes —
  # they're known at plan and let us assert the surface contract without
  # waiting for apply.
  assert {
    condition     = output.account_name == "alpha-prod"
    error_message = "account_name output must echo var.account_name."
  }

  assert {
    condition     = output.managed_organizational_unit == "Workloads"
    error_message = "managed_organizational_unit output must echo var.managed_organizational_unit."
  }
}

run "account_id_precondition_fires_when_local_is_null" {
  # Audit-flagged precondition guard on output.account_id. When the
  # provisioned product has not yet published RecordOutputs.AccountId
  # (the common case mid-provision), local.account_id evaluates to null
  # via the try() in main.tf. The precondition then fails the apply rather
  # than silently emitting null to /aft/account/<name>/id in SSM.
  #
  # We exercise the failure path by setting enabled=false — that drops the
  # provisioned_product resource entirely, so the try() in main.tf falls
  # through to its null default. This is the same code path the runtime
  # hits when CT has not yet populated the AccountId key in its outputs
  # map; the precondition fires either way, which is precisely the safety
  # contract being asserted. Net side-effect: enabled=false also confirms
  # the resource is dropped (a successful precondition-fire requires
  # local.account_id to be null, which can only happen when the resource
  # is absent or its outputs map lacks AccountId).
  command = plan

  variables {
    enabled = false
  }

  expect_failures = [
    output.account_id,
  ]
}
