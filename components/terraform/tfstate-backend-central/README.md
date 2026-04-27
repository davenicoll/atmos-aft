# tfstate-backend-central

Central bootstrap state bucket. Lives **only** in the aft-mgmt account. Stores each enrolled account's own `tfstate-backend` component state, keyed `bootstrap/<account-id>/tfstate-backend/terraform.tfstate` - see `docs/architecture/atmos-model.md` §9.3.3.

Distinct from the per-account `tfstate-backend` component (inventory row 1): same backing module, different shape. This one is aft-mgmt-only, simpler KMS policy, and is the only bucket that ever needs `terraform init -migrate-state` (operator-run, once, during initial bootstrap).

## What it creates

- `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>` S3 bucket
- KMS CMK with alias `alias/atmos-tfstate-bootstrap`
- Bucket policy: `DenyInsecureTransport` + read grant to `AtmosReadAllStateRole`
- KMS key policy: root + `AtmosCentralDeploymentRole` full use + `AtmosReadAllStateRole` decrypt-only
- S3 native locking enabled (`use_lockfile: true`), no DynamoDB

## Bootstrap sequence

Per `docs/architecture/atmos-model.md` §9.3.3 steps 1–2, this component is first applied with **local state** from an operator workstation with aft-mgmt admin creds, then migrated into itself via `terraform init -migrate-state`. After that, every subsequent apply is GHA-driven under `AtmosCentralDeploymentRole`.

## Inputs

- `region` - AWS region
- `aft_mgmt_account_id` - the account this component applies into

## Outputs

- `bucket_id`, `bucket_arn`
- `kms_key_id`, `kms_key_arn`, `kms_alias_name`
