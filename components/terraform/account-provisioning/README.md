# account-provisioning

Vends a new AWS account via the Control Tower Account Factory. Wraps `aws_servicecatalog_provisioned_product` against the CT-managed Service Catalog product. Replaces `cloudposse/terraform-aws-account` (forbidden — see `module-inventory.md` §0.1).

Source of truth: `docs/architecture/mapping.md` §2.1 and `docs/architecture/module-inventory.md` row 30 / §0.1.

## What it creates

One `aws_servicecatalog_provisioned_product` per stack that declares this component. On apply, Service Catalog invokes CT's Account Factory StackSet — the same path AFT uses — and returns the new account ID in `RecordOutputs.AccountId`. The account ID is then surfaced as a component output and published to SSM via a `store-outputs` hook for downstream consumers.

## Which stacks use it

Only `vended` account classes. The four CT-core account stacks (`ct-mgmt`, `aft-mgmt`, `audit`, `log-archive`) do not include this component — those accounts predate Atmos and are never vended through Service Catalog.

## Importing pre-existing CT-vended accounts

For accounts CT vended before Atmos was introduced, import the provisioned product into state rather than letting Terraform try to recreate it:

```bash
atmos terraform import account-provisioning \
  -s <stack> \
  aws_servicecatalog_provisioned_product.account[0] \
  pp-xxxxxxxxxxxxxxx    # from aws servicecatalog scan-provisioned-products
```

The `lifecycle.prevent_destroy = true` guard stops an accidental `atmos terraform destroy` from terminating a healthy account. Removing an account is a deliberate two-step process via `destroy-account.yaml` (`gha-design.md` §5.7).

## Inputs

- `region` — CT management account home region
- `account_name`, `account_email` — account identity
- `managed_organizational_unit` — target OU (must be CT-registered)
- `sso_user_email`, `sso_user_first_name`, `sso_user_last_name` — initial IAM Identity Center user
- `ct_product_id` — Service Catalog product ID for the CT Account Factory product (pin via SSM `/atmos/ct/product-id`)
- `provisioning_artifact_name` — defaults to the CT-managed artifact

## Outputs

- `account_id` — **the critical one**. Consumed by every downstream stack.
- `provisioned_product_id` — used by destroy-account.yaml for `TerminateProvisionedProduct`
- `status` — published as runtime state row (replaces `aft-request-metadata` DDB)
- `account_name`, `account_email`, `managed_organizational_unit` — echoes

## Eventual consistency warning

Per `mapping.md` §9 item 3: Service Catalog returns "completed" when the account exists, but CT guardrails may take 5-15 minutes longer to fully apply. Downstream components that depend on SCP-enforced behaviour should not assume CT is fully settled immediately after this component completes. `provision-account.yaml` handles this with a short post-apply wait step before jobs 5+ run.
