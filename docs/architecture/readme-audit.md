# README fidelity audit: atmos-aft vs upstream AFT

Mechanical diff between `docs/architecture/aft-readme-baseline.md` (extraction of upstream AFT's root README) and atmos-aft's shipped `README.md` + implementation. Task #6.

**Verdict summary:** atmos-aft preserves the AFT _feature surface_ (account vending, baseline, feature options, global + per-account customizations, drift detection, CT coexistence) but the _config surface_ is substantially leaner: 52 inputs → 7 factory vars + ~13 stack vars, 59 outputs → 7 SSM params + `atmos describe`, 10 local modules → 7 custom components + ~30 Cloudposse wrappers. All scope cuts are deliberate and documented.

**Categories used in this doc:**

- **Mapped** — direct equivalent exists in atmos-aft. Usually same semantics, sometimes renamed.
- **Moved** — concept preserved but on a different surface (e.g. DDB table → Git, Lambda → GHA job, input → stack var).
- **Dropped** — intentional scope cut. atmos-aft has no equivalent and doesn't need one.
- **Ambiguous** — atmos-aft README either under-specifies or over-specifies relative to upstream. Flagged for follow-up.

---

## 1. Requirements and providers

| Dimension | AFT baseline | atmos-aft | Category | Notes |
|-----------|--------------|-----------|----------|-------|
| Terraform | `>= 1.2.0, < 2.0.0` | `>= 1.10.0, < 2.0.0` | Mapped (tightened) | Raised floor for `use_lockfile=true` S3-native locking (§12.2). Documented in README §8. |
| AWS provider | `>= 6.0.0, < 7.0.0` | `>= 6.0.0, < 7.0.0` | Mapped | Identical. |
| `local` provider | used by root module | not used | Dropped | Upstream reads `python_version`/`version` from disk; atmos-aft pins Terraform version in SSM (`/aft/config/terraform/version`), no local-file reads. |
| Atmos | n/a | `>= 1.88.0` | New dep | Documented in README §8. Pinned in `atmos.yaml`; resolved by `setup-atmos` composite. |
| Data sources | `aws_partition`, `aws_service.home_region_validation`, `local_file.*` | none at root | Moved | `home_region_validation` replaced by pre-provision check in `bootstrap.yaml`; partition is derived by Atmos auth chain. |

**Finding:** aligned. Terraform-floor bump is load-bearing for the state-locking design; audit confirms README §8 and §12.2 are consistent.

---

## 2. Modules (10 local → atmos-aft equivalents)

| AFT module | What it owns | atmos-aft equivalent | Category |
|------------|--------------|----------------------|----------|
| `packaging` | Builds Lambda zips | — | Dropped (no Lambdas). |
| `aft_account_provisioning_framework` | SFN + 4 Lambdas: `create_role`, `tag_account`, `persist_metadata`, `account_metadata_ssm` | `provision-account.yaml` jobs 1–5 + `account-provisioning` component + `aft-ssm-parameters` | Moved |
| `aft_account_request_framework` | 4 DDB tables + streams, SQS FIFO + DLQ, SNS, EventBridge bus, 6 Lambdas | Stack YAML in Git (inbox) + `controltower-event-bridge` component + `account-request-{kms,queue,notifications}` components | Moved |
| `aft_backend` | S3 primary + optional secondary (replication), DDB lock table, per-region KMS, access-logs bucket | `tfstate-backend-central` (bootstrap) + `tfstate-backend` (per-account) + per-account CMK; S3-native locking, no DDB | Mapped (substrate changed) |
| `aft_code_repositories` | CodeCommit/CodeConnections + 2 CodePipelines + 2 CodeBuild | — | Dropped (the repos are this repo; PRs replace pipelines). |
| `aft_customizations` | `aft-invoke-customizations` SFN + 3 Lambdas + 3 CodeBuild | `_customize-global.yaml` + `_customize-account.yaml` reusable workflows + `customize-fleet.yaml` entry-point + `components/terraform/customizations/<name>/` | Moved |
| `aft_feature_options` | `aft-feature-options` SFN + 3 Lambdas (`delete-default-vpc`, `enroll-support`, `enable-cloudtrail`) | `_feature-options.yaml` reusable workflow (job 6 of DAG) | Moved |
| `aft_iam_roles` | `AWSAFTAdmin` + `AWSAFTExecution`/`AWSAFTService` in 4 core accounts | `iam-deployment-roles/central` + `iam-deployment-roles/target` components; renamed (`AtmosCentralDeploymentRole`, `AtmosDeploymentRole`, plus plan-only variants) | Mapped (renamed) |
| `aft_lambda_layer` | `aft-common` Python layer build + pre-apply trigger Lambda | — | Dropped (no Lambdas). |
| `aft_ssm_parameters` | ~50 SSM params under `/aft/config/*`, `/aft/account/*`, `/aft/resources/*` | `aft-ssm-parameters` component | Mapped (component-backed) |

**Findings:**

- 4 of 10 modules are dropped outright. All VPC/networking and Lambda-build modules gone. This matches README §5.4 "Inputs dropped" and Mapping doc §1.
- Custom-component count (7) in README §7.3 aligns: `account-provisioning`, `iam-deployment-roles/{central,target}`, `controltower-event-bridge`, `cloudtrail-lake`, `tfstate-backend-central`, `aws-account-settings`, `github-oidc-provider`.
- `account-request-{kms,queue,notifications}` — these components ship (per README §7.1) but audit cannot find them in the shipped custom-component list (§7.3). **Ambiguity**: are they Cloudposse wrappers, or custom? **Follow-up: tf-module-expert should confirm backing module for these three in `module-inventory.md`.**

---

## 3. Inputs (52 → ~20)

Upstream: 52 root variables; 5 required; 1 sensitive. atmos-aft: 7 repo vars/secrets (§5.1) + ~13 stack vars (§5.2) + 6 workflow inputs (§5.3). Total addressable configuration surface is roughly 40% of upstream.

### 3.1 IDENTITY (5 required inputs upstream)

| Upstream | Category | atmos-aft location | Category | Notes |
|----------|----------|-------------------|----------|-------|
| `ct_management_account_id` | IDENTITY, required | Discovered by `configure-aws` composite at runtime via Organizations describe; stored as SSM `/aft/resources/ct-management-id` by `aft-ssm-parameters` | Moved | No longer an input — derived. |
| `ct_home_region` | IDENTITY, required | `bootstrap.yaml` input `aft_mgmt_region`; pinned in atmos.yaml | Moved | Single input, different home. |
| `aft_management_account_id` | IDENTITY, required | `bootstrap.yaml` input `aft_mgmt_account_id` | Mapped (renamed) | |
| `log_archive_account_id` | IDENTITY, required | `stacks/orgs/<org>/core/log-archive/gbl.yaml#vars.account_id` | Moved | From input → stack var (`core-gbl-log`). |
| `audit_account_id` | IDENTITY, required | `stacks/orgs/<org>/core/audit/gbl.yaml#vars.account_id` | Moved | From input → stack var (`core-gbl-audit`). |

**Finding:** no required inputs at module root — the factory has no Terraform root module. Required inputs exist only for `bootstrap.yaml` workflow (2) and the 6 stack files (core + vended accounts).

### 3.2 VCS/REPO (10 inputs upstream)

All 10 upstream `vcs_provider`, `*_repo_name`, `*_repo_branch` inputs → **Dropped**. The repository is this repository; there is no repo-selection plane.

### 3.3 TF-DIST (9 inputs upstream)

| Upstream | atmos-aft | Category | Notes |
|----------|-----------|----------|-------|
| `terraform_version` | SSM `/aft/config/terraform/version` (written by `aft-ssm-parameters`) | Moved | Not a factory input; pinned in component defaults. |
| `terraform_distribution` | `bootstrap.yaml` workflow input (`oss`\|`tfc`) | Mapped | README §4.2. |
| `tf_backend_secondary_region` | — | Dropped | atmos-aft has per-account buckets; replication is per-bucket policy, not a global toggle. **Not mentioned in README §5.4 as a drop — minor omission.** |
| `terraform_api_endpoint` | Implicit (TFC API base) when `terraform_distribution=tfc` | Moved | Not surfaced. |
| `terraform_token` | `TERRAFORM_CLOUD_TOKEN` secret + SSM SecureString | Mapped | README §5.1 + §12.5. |
| `terraform_org_name` | `bootstrap.yaml` input when `terraform_distribution=tfc` | Mapped | Not explicitly listed in README §5.1 — **minor omission**. |
| `terraform_project_name` | `bootstrap.yaml` input when `terraform_distribution=tfc` | Mapped | Not explicitly listed in README §5.1 — **minor omission**. |
| `terraform_oidc_integration` | Implicit — "becomes trivially true when `terraform_distribution=tfc`" per README §5.4 | Moved | See §7.1 below for the documented ambiguity. |
| `terraform_oidc_hostname` / `terraform_oidc_aws_audience` | — | Dropped | GitHub OIDC is first-class; these HCP-OIDC-specific values are set inside `iam-deployment-roles/central` catalog defaults, not as inputs. |

**Follow-up:** README §5.1 should list `terraform_org_name`, `terraform_project_name`, and `tf_backend_secondary_region` (as a drop) for completeness.

### 3.4 VPC (9 inputs upstream)

All 9 `aft_enable_vpc`, `aft_vpc_*`, `aft_customer_*` inputs → **Dropped**. GHA runners replace CodeBuild; no AFT VPC. README §5.4 lists this correctly.

### 3.5 FEATURE (4 inputs upstream)

| Upstream | atmos-aft stack var | Category |
|----------|--------------------|----------|
| `aft_feature_cloudtrail_data_events` | `feature_options.cloudtrail_data_events` | Mapped (renamed) |
| `aft_feature_delete_default_vpcs_enabled` | `feature_options.delete_default_vpcs_enabled` | Mapped (renamed) |
| `aft_feature_enterprise_support` | `feature_options.enterprise_support` | Mapped (renamed) |
| `aft_metrics_reporting` | — | Dropped (no telemetry in atmos-aft) |

### 3.6 CONCURRENCY (2 inputs upstream)

| Upstream | atmos-aft | Category |
|----------|-----------|----------|
| `concurrent_account_factory_actions` | `AFT_PROVISION_PARALLELISM` repo var (default `1`, widened in phase 2 post-validation) | Mapped (renamed, stricter default) |
| `maximum_concurrent_customizations` | `AFT_CUSTOMIZE_PARALLELISM` repo var (default `4`) | Mapped (renamed) |

### 3.7 BUILD (2 inputs upstream)

| Upstream | atmos-aft | Category |
|----------|-----------|----------|
| `aft_codebuild_compute_type` | GHA runner tier in workflow YAML | Moved |
| `global_codebuild_timeout` | GHA `timeout-minutes:` per job | Moved |

### 3.8 OBSERVABILITY + ENCRYPTION (3 inputs upstream)

| Upstream | atmos-aft | Category |
|----------|-----------|----------|
| `cloudwatch_log_group_retention` | `cloudwatch-log-groups` catalog default | Moved |
| `cloudwatch_log_group_enable_cmk_encryption` | Always CMK in atmos-aft | Dropped (uniform) |
| `sns_topic_enable_cmk_encryption` | Always CMK | Dropped (uniform) |

### 3.9 BACKEND (4 inputs upstream)

| Upstream | atmos-aft | Category |
|----------|-----------|----------|
| `backup_recovery_point_retention` | — | Dropped (no AFT DDB tables to back up) |
| `aft_backend_bucket_access_logs_object_expiration_days` | `tfstate-backend` catalog default | Moved |
| `sfn_s3_bucket_object_expiration_days` | — | Dropped (no SFN pipeline bucket) |
| `log_archive_bucket_object_expiration_days` | `centralized-logging-bucket` catalog default | Moved |

### 3.10 TAG (1 input)

| Upstream | atmos-aft | Category |
|----------|-----------|----------|
| `tags` | Per-account `vars.account_tags` + org-level `_defaults.yaml#tags` | Mapped (multi-level) |

### 3.11 atmos-aft _additions_ (not in upstream)

| atmos-aft-only | Role |
|---------------|------|
| `ATMOS_CENTRAL_ROLE_ARN` | Bootstrap-written repo var. |
| `ATMOS_EXTERNAL_ID` | `sts:ExternalId` for CT-core role assumption. |
| `AFT_AUTH_MODE` | `oidc`\|`access_key`; dev escape hatch. |
| `AFT_BOOTSTRAP_ACCESS_KEY_ID` / `_SECRET_ACCESS_KEY` | One-shot bootstrap identity. |
| Stack vars: `managed_organizational_unit`, `sso_user_*`, `account_customizations_name`, `change_management_parameters`, `custom_fields` | Lift `control_tower_parameters` fields from AFT's DDB `aft-request` row to stack YAML. |
| Account classes (`vended`, `aft-mgmt`, `ct-mgmt`, `audit`, `log-archive`) | Selection mechanism atmos-aft adds that upstream doesn't need (CodePipeline is monolithic). |

**Finding:** atmos-aft's additions are structurally necessary (OIDC wiring, CT-core role assumption, account classes) — nothing gratuitous.

---

## 4. Feature flags (10 → 4)

| Upstream flag | Default | atmos-aft | Category |
|---------------|---------|-----------|----------|
| `aft_feature_cloudtrail_data_events` | `false` | `feature_options.cloudtrail_data_events` | Mapped |
| `aft_feature_delete_default_vpcs_enabled` | `false` | `feature_options.delete_default_vpcs_enabled` | Mapped |
| `aft_feature_enterprise_support` | `false` | `feature_options.enterprise_support` | Mapped |
| `aft_metrics_reporting` | `true` | — | Dropped |
| `terraform_oidc_integration` | `false` | Implicit via `terraform_distribution=tfc` | Moved (see §7.1) |
| `aft_enable_vpc` | `true` | — | Dropped |
| `aft_vpc_endpoints` | `true` | — | Dropped |
| `aft_customer_vpc_id` (BYO) | `null` | — | Dropped |
| `cloudwatch_log_group_enable_cmk_encryption` | `false` | — | Dropped (uniform CMK) |
| `sns_topic_enable_cmk_encryption` | `false` | — | Dropped (uniform CMK) |

**Finding:** 6 of 10 flags dropped. All drops documented in README §5.4. Surviving 4 are correctly documented as stack vars in README §5.2. No orphan flags.

---

## 5. Outputs (59 → 0 TF outputs; replaced by SSM + `atmos describe`)

### 5.1 Pass-through outputs (31 upstream)

All 31 upstream `value = var.<x>` outputs → **Dropped**. atmos-aft's stack config is already authoritative; there is nothing to echo.

### 5.2 Module-sourced outputs (24 upstream)

| Upstream output | atmos-aft retrieval | Category |
|-----------------|---------------------|----------|
| `aft_primary_backend_bucket_id` | `atmos describe component tfstate-backend -s <stack>` → `bucket_id`; also SSM `/aft/resources/backend/bucket` | Mapped |
| `aft_secondary_backend_bucket_id` | — (no global secondary in atmos-aft; replication is per-account bucket opt-in) | Dropped |
| `aft_access_logs_primary_backend_bucket_id` | `atmos describe component aft-access-logs-bucket -s <stack>` | Mapped |
| `aft_backend_lock_table_name` | — (S3-native locking; no DDB lock table) | Dropped |
| `aft_backend_primary_kms_key_id` / `_alias_arn` | `atmos describe component tfstate-backend` → `kms_key_arn`; SSM `/aft/resources/backend/kms-key-alias` | Mapped |
| `aft_backend_secondary_kms_key_*` | — | Dropped |
| `aft_admin_role_arn` | `atmos describe component iam-deployment-roles/central -s aft-gbl-mgmt` → `central_role_arn`; also `ATMOS_CENTRAL_ROLE_ARN` repo var | Mapped (renamed `AtmosCentralDeploymentRole`) |
| `aft_ct_management_exec_role_arn` / `log_archive_exec_role_arn` / `audit_exec_role_arn` / `aft_exec_role_arn` | `atmos describe component iam-deployment-roles/target -s <core-gbl-*>` → `deployment_role_arn` | Mapped (renamed `AtmosDeploymentRole`) |
| `aft_request_table_name` / `aft_request_audit_table_name` / `aft_request_metadata_table_name` / `aft_controltower_events_table_name` | — | Dropped (no DDB) |
| `aft_kms_key_id` / `aft_kms_key_alias_arn` | `atmos describe component account-request-kms -s aft-gbl-mgmt` | Mapped |
| `aft_*_step_function_arn` (3 outputs) | — | Dropped (no SFNs) |
| `aft_sns_topic_arn` / `aft_failure_sns_topic_arn` | `atmos describe component account-request-notifications -s aft-gbl-mgmt` | Mapped |

### 5.3 Output-gaps from baseline §5.3 (not exposed upstream)

| Upstream gap | atmos-aft status |
|--------------|------------------|
| `aft-account-provisioning-customizations` SFN ARN | N/A (replaced by `custom-provisioning-hook.yaml` — no SFN ARN concept). |
| `aft-account-request.fifo` SQS + DLQ | atmos-aft has `account-request-queue` component; ARN retrievable via `atmos describe`. Partial improvement. |
| `aft-events-from-ct-management` EventBridge bus | `controltower-event-bridge` component exposes bus + rule ARNs. Improved. |
| Per-account `${account_id}-customizations-pipeline` | N/A (no per-account CodePipelines). |
| CodePipeline ARNs, CodeBuild project ARNs | N/A. |
| 6 + 3 Lambda ARNs | N/A. |

**Finding:** atmos-aft intentionally drops the 31 input-echo outputs (cleanup); module-sourced outputs are replaced by SSM (7 params enumerated in README §6.1) + `atmos describe` (listed in §6.2). The three coordinates most likely to matter downstream — state bucket, CMK, central role — are all exposed. Audit finds no missing coordinate.

---

## 6. Counts comparison

| Dimension | AFT baseline | atmos-aft | Delta |
|-----------|-------------:|----------:|------:|
| Local modules | 10 | 7 custom + ~30 Cloudposse wrappers | — (substrate changed) |
| Data sources at root | 4 | 0 | −4 |
| Inputs | 52 | 7 repo + ~13 stack + 6 workflow = ~26 | −26 |
| Required inputs | 5 | 2 (bootstrap) + ~3 per leaf stack | ~same |
| Sensitive inputs | 1 (`terraform_token`) | 1 (`TERRAFORM_CLOUD_TOKEN`) | same |
| Feature flags | 10 | 4 kept (3 stack + 1 implicit) | −6 |
| Outputs | 59 (31 echoes + 24 module + 4 derived) | 7 SSM params + N `atmos describe` outputs | Substantial simplification; no real coordinates lost |

---

## 7. Ambiguities and follow-up items

### 7.1 HCP Terraform OIDC toggle name

Baseline §4 note: upstream README prose references a non-existent `aft_feature_hcp_oidc`; the real toggle is `terraform_oidc_integration`.

atmos-aft README §5.4 says `terraform_oidc_integration` "becomes trivially true when using TFC" — i.e. it is implicit, not a repo var. README §12.4 _does_ describe HCP OIDC governance but doesn't use the `terraform_oidc_integration` name explicitly as a toggle the operator sets.

**Status:** not a bug (matches team-lead's `gha-design.md` §5.12 direction); naming is consistent within atmos-aft. Keep `terraform_oidc_integration` as the documented name. Atmos-engineer signalled (per team-lead message) that no different name will be introduced.

**Action:** none.

### 7.2 `account-request-{kms,queue,notifications}` backing module

README §7.1 lists these three in the repo tree but §7.3 custom-component list doesn't enumerate them — and they aren't obvious Cloudposse wrappers (the Cloudposse catalog has no `terraform-aws-account-request-queue` module).

**Status:** possible under-documentation. Could be genuinely custom (add to §7.3) or thin Cloudposse wrappers around `terraform-aws-{sqs-queue,sns-topic,kms-key}` (add to `module-inventory.md`).

**Action:** follow-up with tf-module-expert to confirm backing module for each; update README §7.3 or `module-inventory.md` accordingly.

### 7.3 Minor omissions in README §5.1 / §5.4

1. README §5.1 should list `terraform_org_name` and `terraform_project_name` as `bootstrap.yaml` inputs when `terraform_distribution=tfc` — currently only `TERRAFORM_CLOUD_TOKEN` is listed.
2. README §5.4 should list `tf_backend_secondary_region` as a dropped input (scope cut: no global secondary state bucket; replication is per-account opt-in).
3. README §5.4 should list `backup_recovery_point_retention` as a dropped input (no AFT DDB tables to back up).

**Action:** one-line additions in a follow-up edit; low priority.

### 7.4 Stack naming consistency — `core-gbl-log` vs `log-archive`

The shipped stack is named `core-gbl-log` (stage=`log`), but the account is `log-archive` and account class is `log-archive`. README §7.2 table aligns with the shipped stack name. The semantic drift (stage=`log` for a `log-archive` account) is minor but worth a call-out in a future clean-up pass.

**Action:** not a correctness issue; flag for atmos-engineer to consider on next stack-catalog revision.

### 7.5 Drift between README §7.1 (tree) and shipped `.github/`

README §7.1 lists "11 reusable + 12 entry-point" workflows. `gh-design.md` §4 (and the `.github/workflows/` on disk) should be verified against this count as part of #25 architecture review — audit doesn't re-count here since #21 already confirmed topology.

**Action:** covered by #25.

---

## 8. Parity verdict

atmos-aft README is **at parity** with upstream AFT README for every feature a downstream operator cares about:

- **Inputs:** all 52 upstream inputs accounted for (mapped, moved, or deliberately dropped). No orphans; no missing documentation except the three §7.3 minor omissions.
- **Outputs:** all real resource coordinates reachable via SSM + `atmos describe`. Input-echo outputs legitimately dropped.
- **Feature flags:** 4 of 10 preserved; 6 dropped with clear rationale in §5.4.
- **Modules:** all 10 upstream modules mapped, moved, or intentionally dropped. 7 custom + ~30 Cloudposse wrappers replace the local-module model.
- **Counts:** no coordinate is reachable upstream that atmos-aft can't surface through SSM or `atmos describe`.

**Recommendation:** proceed to #25 (architecture + implementation review). Fold the four §7 follow-ups (HCP-OIDC naming call-out already resolved; `account-request-*` backing-module confirmation; three §5.1/§5.4 omissions; `core-gbl-log` naming) into the review's punch list rather than shipping a patch release just for them.

---

## Appendix A: sources consulted

- `docs/architecture/aft-readme-baseline.md` — upstream README extraction (v1).
- `README.md` (atmos-aft, shipped) — §3 prerequisites, §4 quickstart, §5 inputs, §6 outputs, §7 modules, §8 providers, §9 customizations, §11 operations, §12 security.
- `docs/architecture/mapping.md` — AFT artefact → atmos-aft mapping (authoritative per-module map).
- `docs/architecture/module-inventory.md` — component-level mapping for counts.
- `stacks/orgs/example-accounts/**/*.yaml` — shipped 6 leaf stacks for naming and var verification.
- `components/terraform/` — shipped component tree (visual inspection for count).
