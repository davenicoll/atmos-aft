# Migration from upstream AFT to atmos-aft

A step-by-step guide for teams currently running [AWS Control Tower Account Factory for Terraform](https://github.com/aws-ia/terraform-aws-control_tower_account_factory) who want to move to atmos-aft.

The migration is incremental. Both systems can coexist in the same AFT-management account during cut-over; atmos-aft takes over account-by-account at a pace the operator controls.

This document is the source of truth; §10 of the root README is a short pointer to here.

---

## 1. Motivation and constraints

atmos-aft does not require migration — it works as a replacement for teams starting fresh on Control Tower. This document covers the harder case: an existing estate managed by AFT that needs to land on atmos-aft without an outage, without losing customizations, and without re-vending accounts.

Constraints that shape the approach:

- **CT-owned resources stay put.** Control Tower continues to own Organizations, OUs, baseline SCPs, the org-level CloudTrail, and the Identity Center instance. Neither AFT nor atmos-aft has ever managed those, so the migration leaves them alone.
- **Vended accounts already exist.** Each is a Service Catalog provisioned-product in the CT management account. Migration means importing that provisioned-product into atmos-aft's Terraform state, not re-vending.
- **State cannot be shared.** AFT's backend is a single S3 bucket with per-repo prefixes. atmos-aft uses per-account buckets with per-account CMKs. We don't migrate state — atmos-aft creates fresh state during import, and AFT's state stays put until the final decommission.
- **Customer repos carry customer IP.** Global and per-account customizations are the operator's own Terraform. These port directly; only the glue around them changes.
- **Downtime is unacceptable.** Accounts already in production must keep working throughout. The migration plans are designed so that at no point is an account ungoverned.

---

## 2. Pre-migration audit

Do this before touching anything. Every item is a data-collection step; none of them mutate state.

### 2.1 Inventory of accounts

Export the full `aft-request-metadata` table:

```bash
aws dynamodb scan \
  --table-name aft-request-metadata \
  --output json \
  > aft-request-metadata.json
```

For each row, capture:

- `id` (account email — primary key)
- `account_name`
- `account_id`
- `ou` (current Managed OU)
- `account_customizations_name` (if set)
- `account_tags`
- `custom_fields` (if set)

That becomes the input to the stack-file generation step (§4.2).

### 2.2 Inventory of customizations

```bash
# Inside the aft-global-customizations repo
find terraform/ -type f -name '*.tf' | sort

# Inside the aft-account-customizations repo
find . -maxdepth 2 -type d -name 'terraform' | sort
```

For each customization directory:

- Note the list of modules it calls (especially anything depending on SSM `/aft/*` keys that atmos-aft renames).
- Note any `api_helpers/pre-api-helpers.sh` or `post-api-helpers.sh` scripts.
- Note any SFN or Lambda code in `aft-account-provisioning-customizations` — that does not port directly (§6).

### 2.3 Inventory of SSM parameters

```bash
aws ssm get-parameters-by-path --path /aft --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' | sort > aft-ssm.txt
```

atmos-aft keeps the `/aft/` namespace but owns a different subset of keys. Note any keys your customizations read so you can verify they survive the cut-over.

### 2.4 Inventory of AFT inputs

Pull the values currently passed to the AFT module. Compare against the 52-input table in [`docs/architecture/aft-readme-baseline.md`](aft-readme-baseline.md) §3 to identify:

- Inputs that are dropped in atmos-aft (e.g. all `aft_vpc_*`, `aft_codebuild_compute_type`, `backup_recovery_point_retention`). Note these for operator sign-off before cut-over.
- Inputs that move to a GitHub repo variable (e.g. `ct_management_account_id`, `log_archive_account_id`).
- Inputs that move to stack YAML (e.g. `account_customizations_repo_branch`).

### 2.5 Inventory of Service Catalog provisioned products

```bash
aws servicecatalog search-provisioned-products \
  --filters 'SearchQuery=type:AWS Control Tower Account Factory' \
  --query 'ProvisionedProducts[].{Name:Name,Id:Id,PhysicalId:PhysicalId,Status:Status}' \
  --output table
```

Each row corresponds to one account currently under AFT. Record the product IDs — they become the `terraform import` arguments in §4.4.

### 2.6 Failed or stuck accounts

Check `aft-account-request-dlq.fifo` — any messages here represent failed provisioning attempts:

```bash
queue_url=$(aws ssm get-parameter --name /aft/resources/sqs/aft-account-request-dlq-fifo --query Parameter.Value --output text)
aws sqs receive-message --queue-url "$queue_url" --max-number-of-messages 10
```

Resolve every DLQ entry (either re-drive into the main queue and let AFT finish, or delete and re-request in atmos-aft after migration). Migrating with unresolved DLQ entries produces ambiguous state.

---

## 3. Side-by-side bootstrap

atmos-aft and AFT run in the same AFT-management account without interfering. They use different IAM role names, different state backends, different DDB tables (atmos-aft uses none), different CodeBuild/GHA surfaces.

### 3.1 Clone and configure

```bash
git clone git@github.com:<your-org>/atmos-aft.git
cd atmos-aft

# Set the repo variables listed in README §5.1
gh variable set AFT_EXTERNAL_ID --body "$(uuidgen)"
gh variable set AFT_AUTH_MODE --body oidc
# ... and the rest
```

### 3.2 Run the bootstrap workflow

Trigger `bootstrap.yaml` with inputs pointing at the **same** AFT-management account AFT already uses. The workflow creates:

- `AtmosCentralDeploymentRole` in AFT-mgmt (alongside AFT's `AWSAFTAdmin`).
- `AtmosDeploymentRole` in CT-mgmt, audit, log-archive, AFT-mgmt (alongside AFT's `AWSAFTExecution`).
- `github-oidc-provider` in AFT-mgmt.
- Per-account `tfstate-backend` buckets + per-account CMKs (new, distinct from AFT's `aft-backend-*` bucket).
- Security-service delegated-admin already in place from AFT — atmos-aft's bootstrap detects and skips.

Nothing in this step affects AFT's runtime. Verify AFT is still green:

```bash
aws codepipeline list-pipelines --query 'pipelines[].name' | grep ct-aft
# Should still show ct-aft-account-request and ct-aft-account-provisioning-customizations
```

### 3.3 Gate atmos-aft workflows off

Until the first account is imported, disable every atmos-aft entry-point workflow except `bootstrap.yaml` and `pr.yaml`. This prevents accidental dispatches against AFT-owned accounts.

```bash
gh workflow disable provision-account.yaml
gh workflow disable customize-fleet.yaml
gh workflow disable destroy-account.yaml
gh workflow disable drift-detection.yaml
```

Re-enable each as the migration progresses (§5).

---

## 4. Account-by-account import

Work through the estate one account at a time. A typical pace is one account per day during the first week, then faster once the pattern is familiar. A single dry-run per account before the live import is strongly recommended.

### 4.1 Pick an account to import first

Choose the least-critical account (a sandbox or dev account) for the first import. Avoid:

- Accounts with in-flight AFT provisioning (wait for the CodePipeline to go green).
- Accounts whose customizations are actively being edited in the AFT customer repos.
- Shared-service accounts (log-archive, audit) — those come last.

### 4.2 Author the stack YAML

Translate the account's `aft-request-metadata` row into a stack YAML:

```yaml
# stacks/orgs/<your-org>/<tenant>/<account-short-name>/<region>.yaml
import:
  - catalog/account-provisioning/defaults
  - mixins/tenant/<tenant>
  - mixins/stage/<stage>
  - mixins/region/<region>

vars:
  account_name: <from DDB row>
  account_email: <from DDB row.id>
  managed_organizational_unit: <from DDB row.ou>
  account_customizations_name: <from DDB row.account_customizations_name, if set>
  account_tags: <from DDB row.account_tags>
  custom_fields: <from DDB row.custom_fields, if any>
  feature_options:
    delete_default_vpcs_enabled: <from original AFT input>
    enterprise_support: <from original AFT input>
    cloudtrail_data_events: <from original AFT input>
```

Open a PR — `pr.yaml` runs `atmos terraform plan` read-only. **Expected diff at this point: everything is an "add"** because atmos-aft has no state for this account yet. Do not merge yet.

### 4.3 Generate the import commands

```bash
scripts/import-existing-accounts.sh <account-id>
```

The script queries Service Catalog for the provisioned-product ID, queries Organizations for the account's OU, queries IAM for existing role ARNs, and prints a sequence of `terraform import` commands covering:

- `aws_servicecatalog_provisioned_product.this` (the account itself).
- `aws_iam_role.atmos_deployment_role` in the target account (if AFT created one with the same name — unlikely, but possible).
- Anything else the per-component import hook declares.

### 4.4 Run the import workflow

```bash
gh workflow run import-existing-account.yaml \
  --field stack=<tenant>-<region>-<stage>-<account-short-name> \
  --field servicecatalog_provisioned_product_id=<pp-id-from-§4.3>
```

The workflow:

1. Assumes `AtmosCentralDeploymentRole` → `AWSControlTowerExecution` in the target (because `AtmosDeploymentRole` is not yet stamped).
2. Creates per-account `tfstate-backend` bucket + CMK.
3. Stamps `AtmosDeploymentRole` in the target.
4. Runs the `terraform import` commands from §4.3.
5. Runs `atmos terraform plan` — **expected diff now: zero or near-zero**. A small diff is acceptable if it reflects atmos-aft's extra guardrails (KMS alias, tag key differences). A large diff is a red flag; stop and investigate.

### 4.5 Merge and verify

Merge the PR. `push-main.yaml` skips `provision-account.yaml` because the account is already `status=imported` in SSM. Verify:

```bash
aws ssm get-parameter --name /aft/account/<name>/status --query Parameter.Value
# Expected: imported
aws ssm get-parameter --name /aft/account/<name>/account-id --query Parameter.Value
# Expected: the original account ID
```

At this point, atmos-aft and AFT both "own" the account in the sense that both would re-apply their Terraform. Neither can cause damage as long as:

- AFT's `aft-request` row for this account is left in place (AFT keeps thinking it owns the account).
- The account is **not** edited through AFT's customer repos during the cut-over window.

Freeze edits to this account's AFT customizations for the duration of the migration.

### 4.6 Decommission the account from AFT

Once atmos-aft's plan is clean:

```bash
# 1. Delete the row from aft-request DDB
account_email=<from DDB row.id>
table=$(aws ssm get-parameter --name /aft/resources/ddb/aft-request --query Parameter.Value --output text)
aws dynamodb delete-item --table-name "$table" --key "{\"id\":{\"S\":\"$account_email\"}}"
```

AFT's `aft-account-request-action-trigger` Lambda fires with a `REMOVE` event and invokes `aft-cleanup-resources`. **The cleanup Lambda deletes AFT-managed state and IAM roles that AFT itself stamped into the account** — it does not touch atmos-aft's `AtmosDeploymentRole`, the per-account `tfstate-backend` bucket, or any customization state. Verify by watching:

```bash
aws logs tail /aws/lambda/aft-cleanup-resources --follow
```

Wait for the Lambda to finish (typically 2–5 minutes).

### 4.7 Run atmos-aft's provisioning baseline

```bash
gh workflow run customize-fleet.yaml --field scope=stack:<stack-name>
```

This runs the global + per-account customization stages against the imported account. Expected: the customizations that were running under AFT now run under atmos-aft; state lives in the per-account bucket.

### 4.8 Sign-off checklist for one account

Before moving to the next account:

- [ ] `atmos terraform plan` on every component in the stack is clean.
- [ ] `/aft/account/<name>/status` is `customized`.
- [ ] Customizations that depend on specific SSM keys still resolve.
- [ ] No drift in CT's console for the account.
- [ ] AFT's `aft-request` no longer has the row; `aft-cleanup-resources` has completed.
- [ ] Stakeholders notified that this account is now under atmos-aft.

---

## 5. Customization migration

Customization code ports 1:1. The AFT-specific glue does not.

### 5.1 Global customizations

Copy the contents of `aft-global-customizations/terraform/` into `components/terraform/customizations/global/`:

```bash
cp -r ../aft-global-customizations/terraform/* components/terraform/customizations/global/
```

Changes to make:

- **Delete `backend.jinja`.** atmos-aft renders backends natively. The `stacks/catalog/customizations/global/defaults.yaml` declares the backend for you.
- **Delete `aft-providers.jinja`.** atmos-aft configures provider assume-role via the `auth:` block in `atmos.yaml`.
- **Replace Jinja variables.** Upstream used `{{ ssm_account_id }}`, `{{ target_admin_role_arn }}`, etc. Replace with Atmos equivalents:

| Upstream Jinja | atmos-aft replacement |
|----------------|-----------------------|
| `{{ aft_admin_role_arn }}` | Resolved by Atmos auth chain — remove the reference. |
| `{{ target_admin_role_arn }}` | Resolved by Atmos auth chain — remove. |
| `{{ vended_account_id }}` | `var.account_id`, populated from `!store` or stack var. |
| `{{ ssm_account_id }}` | Remove; runtime auth fills this in. |
| `{{ tf_s3_bucket }}` / `{{ tf_s3_key }}` / `{{ tf_dynamodb_table }}` | Declared in stack catalog; remove the Jinja. |

- **Keep `api_helpers/pre-api-helpers.sh` and `post-api-helpers.sh`.** These run as GHA composite action steps (`.github/actions/run-api-helpers/`). Update any hard-coded AFT role names:

```bash
# Old
aws --profile aft-target ...
# New — rely on the aws-actions/configure-aws-credentials session
aws ...
```

### 5.2 Per-account customizations

Same process, per directory. Each `<name>/` under `aft-account-customizations/` becomes `components/terraform/customizations/<name>/`. The stack YAML opts in via `vars.account_customizations_name: <name>`.

### 5.3 Provisioning customizations SFN

This is the one component that does not port directly. AFT's customer-owned `aft-account-provisioning-customizations` Step Function is usually a mix of Lambda tasks, `Choice` states, manual approvals, and occasional `Wait` states. Rewrite as GHA jobs in `custom-provisioning-hook.yaml`:

| AFT SFN construct | atmos-aft GHA equivalent |
|-------------------|---------------------------|
| `Task` with Lambda invocation | Job with `run:` or composite action. Lambda code runs inline via `aws lambda invoke` or is inlined as shell. |
| `Choice` with `Not`/`And`/`Or` conditions | Job with `if:` expression. |
| `Parallel` with branches | Matrix strategy, or separate jobs with no `needs:` between them. |
| `Wait` with `Seconds` | `run: sleep N`. Rare — usually you can remove the wait and rely on retries. |
| Manual approval via SNS + user action | `environment:` with required reviewers. |
| ServiceNow ticket creation | HTTP call in a job step with `SERVICENOW_TOKEN` secret. |

Port incrementally. For accounts already migrated, the hook is a no-op until you add the logic back. Plan this as a separate workstream, not a prerequisite for account migration.

### 5.4 Testing the customizations

Run `customize-fleet.yaml --scope=stack:<migrated-stack> --dry_run=true` before the first live apply. `dry_run` runs `atmos terraform plan` only and produces a summary in the GHA job log.

---

## 6. Special cases

### 6.1 Shared accounts (ct-management, log-archive, audit)

These accounts exist before AFT and before atmos-aft. AFT treats them specially via `shared_account_request` logic. atmos-aft manages them as regular stacks under `stacks/orgs/<org>/core/`. Import them last — their customizations usually touch org-wide resources (Organizations, SCPs, CloudTrail), so bugs have blast radius.

Import pattern is the same as §4, except:

- The import workflow targets the `core/` OU convention.
- `AtmosDeploymentRole` was already stamped during bootstrap — no `OrganizationAccountAccessRole` fallback needed.
- Customizations for these accounts often live in `aft-global-customizations` but are conditional on `data.aws_caller_identity.current.account_id`. Port the conditionals verbatim.

### 6.2 Accounts with pending CT parameter updates

If an account has `control_tower_parameters` queued for update in AFT but not yet applied (SQS message in `aft-account-request.fifo`):

1. Wait for AFT to process the message (check CloudPipeline, SFN, CT Account Factory).
2. Verify the update landed in CT.
3. Then import as per §4.

Do not import mid-update — the stack YAML will drift from reality.

### 6.3 Accounts with customization failures in AFT

If an account's per-account CodePipeline (`<account-id>-customizations-pipeline`) is currently failing:

1. Resolve the failure in AFT first (fix the customization, let the pipeline go green).
2. Or: import the account with `skip_customizations=true`, then fix the customization in atmos-aft and re-run `customize-fleet.yaml`.

### 6.4 Accounts in non-home regions

atmos-aft, like AFT, runs from the CT home region. Accounts with additional regional stacks need one stack file per region (`<account>/<region>.yaml`). Import the home-region stack first, verify, then add additional region stacks as separate PRs.

### 6.5 HCP Terraform / TFC users

If you run AFT with `terraform_distribution=tfc`, customization state lives in HCP workspaces, not S3. atmos-aft supports the same mode (`terraform_distribution=tfc` in repo variables). The migration path is:

1. Bootstrap atmos-aft with `terraform_distribution=tfc`.
2. For each account, create the new HCP workspace matching atmos-aft's naming (`atmos-<account-id>-<component>`).
3. Migrate state: `terraform state pull` from AFT's workspace → `terraform state push` into atmos-aft's workspace. State transplants work because the resource addresses are identical post-import.
4. Import as per §4.

This is more involved than OSS mode. Consider switching to OSS during migration and back to TFC afterwards if that simplifies the moving parts.

---

## 7. Decommissioning AFT

Only do this after the **last** account is imported and has been stable under atmos-aft for at least a week.

### 7.1 Final verification

- [ ] Every `aft-request-metadata` row has been deleted.
- [ ] `aft-request` table is empty.
- [ ] Every account has `/aft/account/<name>/status` set by atmos-aft.
- [ ] No AFT CodePipeline has run in the last seven days.
- [ ] No SQS messages pending in `aft-account-request.fifo` or its DLQ.
- [ ] `drift-detection.yaml` has produced a clean run against every stack.

### 7.2 Destroy the AFT Terraform root module

```bash
cd <path-to-your-aft-deployment>
terraform plan -destroy
# Review carefully; expected: removal of all AFT resources except the state backend.
terraform destroy
```

The destroy removes: DDB tables, SQS queues, SNS topics, Step Functions, CodeBuild projects, CodePipelines, EventBridge rules, the aft-common Lambda layer, all AFT Lambdas, the AFT VPC and subnets, `AWSAFTAdmin`/`AWSAFTExecution`/`AWSAFTService` roles in every account, CloudWatch log groups, KMS keys.

### 7.3 Archive AFT state and customer repos

- Keep the `aft-backend-*` S3 bucket for a retention window (30–90 days) as an audit trail, then delete. It contains the Terraform state that produced the estate you just migrated.
- Archive the four AFT customer repos (`aft-account-request`, `aft-account-provisioning-customizations`, `aft-global-customizations`, `aft-account-customizations`) to a read-only state. Do not delete — historical git log is still useful.

### 7.4 Clean up SSM parameters

atmos-aft keeps `/aft/account/<name>/*` and a small set of `/aft/config/*` and `/aft/resources/*` parameters. AFT wrote additional keys under the same namespace. Remove them:

```bash
# List keys AFT wrote but atmos-aft doesn't use
comm -23 <(aws ssm get-parameters-by-path --path /aft --recursive --query 'Parameters[].Name' --output text | tr '\t' '\n' | sort) \
         <(cat <atmos-aft-ssm-keys.txt>) \
  > aft-only-ssm-keys.txt

# Delete them
xargs -n1 -a aft-only-ssm-keys.txt aws ssm delete-parameter --name
```

The definitive atmos-aft SSM key list is derived from `components/terraform/aft-ssm-parameters/` + every component with a `stores:` block in its catalog defaults.

### 7.5 Post-migration review

- Document the migration in a runbook update: accounts imported, dates, issues encountered, workarounds applied.
- Audit the customizations that ported cleanly vs those that needed rework (§5.3 most commonly). Update `custom-provisioning-hook.yaml` with any shared patterns that multiple accounts want.
- Turn on atmos-aft's scheduled workflows (`drift-detection.yaml`, `customize-fleet.yaml`, `vendor-refresh.yaml`) if not already enabled.
- Rotate any bootstrap access keys that were used during the migration.

---

## 8. Rollback

Migration is low-risk but not zero-risk. If the imported state diverges from reality and the divergence cannot be reconciled in-place:

1. **Do not delete atmos-aft's state.** Even if it's wrong, it's a record of what atmos-aft believed to be true.
2. Re-add the account's `aft-request` row to the AFT DDB table with the original `id`/email. AFT will re-claim the account (no re-vending — the account already exists).
3. In atmos-aft, run `destroy-account.yaml --stack=<stack> --confirm_account_id=<id>` — but **edit the destroy workflow beforehand** to skip the Service Catalog termination step (the account is still live under AFT now).
4. The destroy workflow removes `AtmosDeploymentRole` and the per-account `tfstate-backend` bucket/CMK. Verify AFT customizations still run clean.
5. Mark the stack YAML as deleted in a follow-up PR.

Full rollback of the bootstrap (removing atmos-aft entirely) is `terraform destroy` of the atmos-aft root stack — same as §7.2 but pointed at atmos-aft's bootstrap state. This leaves AFT intact since the two systems are state-isolated.

---

## 9. Migration artefact mapping

Quick reference for what maps to what during the cut-over. Fuller detail in [`docs/architecture/mapping.md`](mapping.md).

| AFT artefact | atmos-aft replacement | Migration action |
|--------------|-----------------------|-------------------|
| `aft-request` DDB row | Stack YAML file | Author in atmos-aft; delete row from DDB after import. |
| `aft-request-metadata` DDB row | `atmos describe stacks` + SSM `/aft/account/<name>/*` | Discarded; regenerated from stack config. |
| `aft-request-audit` DDB rows | CloudTrail Lake + `git log` | Archive as part of §7.3. |
| `aft-controltower-events` DDB rows | EventBridge → repository_dispatch | Archive as part of §7.3. |
| `aft-request.fifo` SQS | `concurrency:` group in `provision-account.yaml` | Drain and delete as part of §7.2. |
| `AWSAFTAdmin` IAM role | `AtmosCentralDeploymentRole` | Replaced by bootstrap; destroy with §7.2. |
| `AWSAFTExecution` IAM role | `AtmosDeploymentRole` | Replaced per-account during import; destroy with §7.2. |
| `AWSAFTService` IAM role | Not replaced | Destroy with §7.2; no direct analogue needed. |
| `aft-account-provisioning-framework` SFN | `provision-account.yaml` GHA workflow | Replaced; destroy with §7.2. |
| `aft-invoke-customizations` SFN | `customize-fleet.yaml` + matrix | Replaced; destroy with §7.2. |
| `aft-feature-options` SFN | Jobs 6a–6c inside `provision-account.yaml` | Replaced; destroy with §7.2. |
| `aft-account-provisioning-customizations` SFN (customer-owned) | `custom-provisioning-hook.yaml` | Rewrite per §5.3. |
| `ct-aft-account-request` CodePipeline | `pr.yaml` + `push-main.yaml` | Replaced; destroy with §7.2. |
| `ct-aft-account-provisioning-customizations` CodePipeline | `pr.yaml` + `push-main.yaml` | Replaced; destroy with §7.2. |
| `<account-id>-customizations-pipeline` (per-account) | GHA matrix in `customize-fleet.yaml` | Replaced; destroy with §7.2. |
| `aft-backend-*` S3 bucket | Per-account `atmos-tfstate-*` buckets | New, not migrated. Archive original per §7.3. |
| `aft-backend-*` DDB lock table | S3-native locking (`use_lockfile=true`) | Replaced; destroy with §7.2. |
| 6 Lambdas in `aft_account_request_framework` | Not needed | Destroy with §7.2. |
| 3 Lambdas in `aft_feature_options` | Not needed — logic moved into GHA jobs | Destroy with §7.2. |
| 3 Lambdas in `aft_customizations` | `atmos describe affected` + composite actions | Destroy with §7.2. |
| `aft-common` Lambda layer | Not needed | Destroy with §7.2. |
| AFT VPC + 17 endpoints | Not needed (GHA runners) | Destroy with §7.2. |

---

## 10. Time estimate

Rough guidance. Adjust for your estate size and customization complexity.

| Phase | Small estate (< 25 accounts) | Medium (25–100) | Large (> 100) |
|-------|------------------------------|-----------------|----------------|
| Pre-migration audit (§2) | 1 day | 2–3 days | 1 week |
| Side-by-side bootstrap (§3) | 1 day | 1 day | 1 day |
| Account-by-account import (§4) | 1 account/day × N | 2–5 accounts/day | 5–10 accounts/day |
| Customization migration (§5) | Parallel with import; add 1 week for SFN rewrite if needed. | 2–3 weeks | 4–6 weeks |
| Shared-account migration (§6.1) | 1–3 days | 3–5 days | 1 week |
| AFT decommission (§7) | 1 day | 1 day | 1 day |

Expect the longest tail on the customization SFN rewrite (§5.3). That's customer-authored logic with no mechanical conversion; budget accordingly.
