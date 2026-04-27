# tfstate-backend

Per-account primary state backend (S3 + CMK, no DDB). One instance per (account, region).

Source of truth: `docs/architecture/module-inventory.md` row 1 + §2.6, `docs/architecture/atmos-model.md` §9.3.

## What it creates

1. **S3 bucket** `atmos-tfstate-<account_id>-<region>` (overridable) with versioning, BPA, SSE-KMS.
2. **KMS CMK** aliased `alias/atmos-tfstate` (overridable) owned by the module.
3. **DenyInsecureTransport** bucket policy statement (injected via `source_policy_documents`).
4. **Cross-account read** grant for `AtmosReadAllStateRole` in aft-mgmt (bucket policy + KMS Decrypt scoped by `kms:ViaService`).
5. **S3 native locking** (`use_lockfile=true`) - no DynamoDB lock table.

## Topology

Single wrapper, two deployment shapes (this one vs `tfstate-backend-central`). See module-inventory §2.6.

## Inputs

- `region` (required)
- `aft_mgmt_account_id` (required, 12-digit) - cross-account read grantee
- `bucket_name_override` (optional) - only for migrations or legacy names
- `kms_alias_override` (optional)

## Outputs

- `bucket_id`, `bucket_arn`, `bucket_domain_name`
- `kms_key_id`, `kms_key_arn`, `kms_alias_name`
