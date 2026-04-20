locals {
  enabled = module.this.enabled

  # CT Account Factory product name is fixed by Control Tower.
  ct_product_name = "AWS Control Tower Account Factory"

  # Provisioning parameters. The CT Account Factory Service Catalog product
  # accepts the parameters below; every new vended account supplies its own.
  # See: https://docs.aws.amazon.com/controltower/latest/userguide/account-factory.html
  provisioning_parameters = [
    { key = "AccountName", value = var.account_name },
    { key = "AccountEmail", value = var.account_email },
    { key = "ManagedOrganizationalUnit", value = var.managed_organizational_unit },
    { key = "SSOUserEmail", value = var.sso_user_email },
    { key = "SSOUserFirstName", value = var.sso_user_first_name },
    { key = "SSOUserLastName", value = var.sso_user_last_name },
  ]
}

resource "aws_servicecatalog_provisioned_product" "account" {
  count = local.enabled ? 1 : 0

  name                       = "atmos-account-${var.account_name}"
  product_id                 = var.ct_product_id
  provisioning_artifact_name = var.provisioning_artifact_name

  # Each provisioning parameter becomes one block.
  dynamic "provisioning_parameters" {
    for_each = local.provisioning_parameters
    content {
      key   = provisioning_parameters.value.key
      value = provisioning_parameters.value.value
    }
  }

  # Service Catalog provisioning can take 20-40 minutes for CT to finish
  # OU placement + guardrail application. Terraform's default apply timeout
  # (60m) covers this, but be explicit to avoid surprises on slow orgs.
  accept_language = "en"

  tags = merge(module.this.tags, {
    "atmos:account-class" = "vended"
    "atmos:account-name"  = var.account_name
    "atmos:account-email" = var.account_email
  })

  lifecycle {
    # CT emits its own tags and may update certain fields on guardrail changes
    # — ignore the noisy ones to keep drift clean.
    ignore_changes = [
      tags["aws:servicecatalog:provisioningPrincipalArn"],
      tags["aws:servicecatalog:provisioningArtifactIdentifier"],
    ]

    # Prevent accidental re-provision (would terminate + recreate the account).
    prevent_destroy = true
  }
}

# Derive the new account ID from the provisioned product's RecordOutputs.
# CT populates 'AccountId' in the provisioned product outputs; surface it as
# a component output so downstream jobs (iam-deployment-roles/target, etc.)
# can consume it via !store.
locals {
  pp_outputs = try(
    { for o in aws_servicecatalog_provisioned_product.account[0].outputs : o.key => o.value },
    {}
  )

  account_id = try(local.pp_outputs["AccountId"], null)
}
