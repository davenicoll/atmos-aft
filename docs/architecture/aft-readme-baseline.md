# Upstream AFT README baseline

Mechanical extraction from `./reference/aft/README.md` (the `BEGIN_TF_DOCS` / `END_TF_DOCS` block and surrounding sections). Source-module attribution for outputs is derived from `./reference/aft/outputs.tf`.

This is a working artifact for task #6 (README fidelity audit). No cross-referencing to atmos-aft design here — that is the audit's job when phase 2 lands a root README.

---

## 1. Requirements and Providers

| Name | Version |
|------|---------|
| terraform | `>= 1.2.0, < 2.0.0` |
| aws | `>= 6.0.0, < 7.0.0` |
| local | n/a |

Data sources used by root module:

| Name | Type |
|------|------|
| `aws_partition.current` | data source |
| `aws_service.home_region_validation` | data source |
| `local_file.python_version` | data source |
| `local_file.version` | data source |

---

## 2. Modules

All ten are local submodules (`./modules/...`), no pinned versions.

| Module key | Source | Role |
|------------|--------|------|
| `packaging` | `./modules/aft-archives` | Builds Lambda deployment archives from `src/aft_lambda/`. Pure build-time; no AWS resources. |
| `aft_account_provisioning_framework` | `./modules/aft-account-provisioning-framework` | Owns the `aft-account-provisioning-framework` Step Function and its 4 Lambdas (`create_role`, `tag_account`, `persist_metadata`, `account_metadata_ssm`). |
| `aft_account_request_framework` | `./modules/aft-account-request-framework` | Request ingestion: 4 DDB tables + streams, SQS FIFO + DLQ, 2 SNS topics, EventBridge custom bus + rules, 6 Lambdas. |
| `aft_backend` | `./modules/aft-backend` | Terraform state: S3 primary (+ optional secondary with replication), DDB lock table, per-region KMS keys, S3 access-logs bucket. |
| `aft_code_repositories` | `./modules/aft-code-repositories` | Customer repos (CodeCommit when `vcs_provider=codecommit`; CodeConnections otherwise), 2 CodeBuild projects, 2 static CodePipelines. |
| `aft_customizations` | `./modules/aft-customizations` | Per-account customization runtime: `aft-invoke-customizations` SFN, 3 Lambdas, 3 CodeBuild projects (`aft-global-customizations-terraform`, `aft-account-customizations-terraform`, `aft-create-pipeline`), pipeline S3 bucket. |
| `aft_feature_options` | `./modules/aft-feature-options` | Post-provisioning feature toggles: `aft-feature-options` SFN + 3 Lambdas (`delete-default-vpc`, `enroll-support`, `enable-cloudtrail`). Log bucket in log-archive. |
| `aft_iam_roles` | `./modules/aft-iam-roles` | Creates `AWSAFTAdmin` (aft-mgmt) and `AWSAFTExecution`/`AWSAFTService` in ct-management, log-archive, audit, aft-management. |
| `aft_lambda_layer` | `./modules/aft-lambda-layer` | CodeBuild project that builds the `aft-common` Python layer; pre-apply trigger Lambda. |
| `aft_ssm_parameters` | `./modules/aft-ssm-parameters` | Publishes ~50 SSM parameters under `/aft/config/*`, `/aft/account/*`, `/aft/resources/*` — the cross-component config plane. |

---

## 3. Inputs

52 inputs total. Tagged with a category for downstream grouping (`IDENTITY`, `VCS`, `REPO`, `VPC`, `FEATURE`, `BACKEND`, `TF-DIST`, `CONCURRENCY`, `OBSERVABILITY`, `ENCRYPTION`, `BUILD`, `TAG`, `FRAMEWORK`, `METRICS`).

| Name | Type | Default | Required | Category | Description (behaviour summary) |
|------|------|---------|:--------:|----------|---------------------------------|
| `ct_management_account_id` | `string` | n/a | **yes** | IDENTITY | CT management account. Providers assume `AWSControlTowerExecution` into it. |
| `ct_home_region` | `string` | n/a | **yes** | IDENTITY | Region CT is deployed in; AFT must run from here. Validated against `aws_service.home_region_validation`. |
| `aft_management_account_id` | `string` | n/a | **yes** | IDENTITY | AFT management account; host of most AFT runtime (DDB, SFN, Lambda, state backend). |
| `log_archive_account_id` | `string` | n/a | **yes** | IDENTITY | Log-archive CT shared account; target of AFT log bucket and `AWSAFTExecution`. |
| `audit_account_id` | `string` | n/a | **yes** | IDENTITY | Audit CT shared account; gets `AWSAFTExecution`. |
| `vcs_provider` | `string` | `"codecommit"` | no | VCS | One of `codecommit`, `bitbucket`, `github`, `githubenterprise`, `gitlab`, `gitlab selfmanaged`. Selects CodeCommit branch vs CodeConnections branch in `aft_code_repositories`. |
| `github_enterprise_url` | `string` | `"null"` | no | VCS | Host URL for GitHub Enterprise CodeConnections host resource. |
| `gitlab_selfmanaged_url` | `string` | `"null"` | no | VCS | Host URL for GitLab self-managed CodeConnections host resource. |
| `account_request_repo_name` | `string` | `"aft-account-request"` | no | REPO | Repo name; `Org/Repo` for non-CodeCommit. Consumed by `ct-aft-account-request` pipeline. |
| `account_request_repo_branch` | `string` | `"main"` | no | REPO | Branch for account-request repo source action. |
| `account_provisioning_customizations_repo_name` | `string` | `"aft-account-provisioning-customizations"` | no | REPO | Repo for customer-owned `aft-account-provisioning-customizations` SFN Terraform. |
| `account_provisioning_customizations_repo_branch` | `string` | `"main"` | no | REPO | Branch for provisioning customizations repo. |
| `global_customizations_repo_name` | `string` | `"aft-global-customizations"` | no | REPO | Repo applied to every AFT account via per-account pipeline global stage. |
| `global_customizations_repo_branch` | `string` | `"main"` | no | REPO | Branch. |
| `account_customizations_repo_name` | `string` | `"aft-account-customizations"` | no | REPO | Repo for named per-account customization directories. |
| `account_customizations_repo_branch` | `string` | `"main"` | no | REPO | Branch. |
| `aft_framework_repo_url` | `string` | `"https://github.com/aws-ia/terraform-aws-control_tower_account_factory.git"` | no | FRAMEWORK | Source of AFT module itself — cloned by `aft-create-pipeline` and similar to render templates. |
| `aft_framework_repo_git_ref` | `string` | `null` | no | FRAMEWORK | Git branch / ref for framework clone. `null` = module's default. |
| `terraform_version` | `string` | `"1.6.0"` | no | TF-DIST | TF version installed in every buildspec. Published as SSM `/aft/config/terraform/version`. |
| `terraform_distribution` | `string` | `"oss"` | no | TF-DIST | One of `oss`, `tfc`, `tfe`. Drives backend.jinja choice (S3 vs HCP) and OIDC trust policy wiring. |
| `tf_backend_secondary_region` | `string` | `""` | no | BACKEND | Empty = no replica. Non-empty = create secondary S3 bucket + KMS + replication. |
| `terraform_api_endpoint` | `string` | `"https://app.terraform.io/api/v2/"` | no | TF-DIST | HCP/TFE API base; SecureString-adjacent in SSM. |
| `terraform_token` | `string` | `"null"` | no | TF-DIST | HCP/TFE API token. Stored as SecureString SSM. **Sensitive in Terraform state.** |
| `terraform_org_name` | `string` | `"null"` | no | TF-DIST | HCP/TFE organisation name. |
| `terraform_project_name` | `string` | `"Default Project"` | no | TF-DIST | HCP/TFE project; used in OIDC `sub` claim condition. Must exist pre-deploy. |
| `terraform_oidc_integration` | `bool` | `false` | no | TF-DIST / FEATURE | Enable HCP OIDC-to-AWS dynamic credentials. Toggles the wildcard-workspace trust clause on `AWSAFTAdmin`. |
| `terraform_oidc_hostname` | `string` | `"app.terraform.io"` | no | TF-DIST | OIDC provider hostname; used in `sub` claim. |
| `terraform_oidc_aws_audience` | `string` | `"aws.workload.identity"` | no | TF-DIST | OIDC audience value. |
| `aft_enable_vpc` | `bool` | `true` | no | VPC | Master toggle for AFT-managed VPC and subnets. |
| `aft_vpc_endpoints` | `bool` | `true` | no | VPC | Create VPC interface/gateway endpoints for AWS services used by Lambda/CodeBuild. |
| `aft_vpc_cidr` | `string` | `"192.168.0.0/22"` | no | VPC | AFT VPC CIDR. |
| `aft_vpc_private_subnet_01_cidr` | `string` | `"192.168.0.0/24"` | no | VPC | Private subnet 1. |
| `aft_vpc_private_subnet_02_cidr` | `string` | `"192.168.1.0/24"` | no | VPC | Private subnet 2. |
| `aft_vpc_public_subnet_01_cidr` | `string` | `"192.168.2.0/25"` | no | VPC | Public subnet 1. |
| `aft_vpc_public_subnet_02_cidr` | `string` | `"192.168.2.128/25"` | no | VPC | Public subnet 2. |
| `aft_customer_vpc_id` | `string` | `null` | no | VPC | BYO-VPC: if set, AFT uses this VPC instead of creating one. New deployments only. |
| `aft_customer_private_subnets` | `list(string)` | `[]` | no | VPC | BYO-subnets list (new deployments only). |
| `aft_feature_cloudtrail_data_events` | `bool` | `false` | no | FEATURE | Enable CloudTrail data-events (S3/Lambda object-level) in the vended account, via `aft-feature-options` SFN. |
| `aft_feature_delete_default_vpcs_enabled` | `bool` | `false` | no | FEATURE | Delete default VPCs in every region on vended account. |
| `aft_feature_enterprise_support` | `bool` | `false` | no | FEATURE | Enrol vended account in AWS Enterprise Support (requires payer account eligibility). |
| `aft_metrics_reporting` | `bool` | `true` | no | METRICS | Opt-out of anonymous operational metrics collection (sent to AWS). |
| `concurrent_account_factory_actions` | `number` | `5` | no | CONCURRENCY | Upper bound on parallel Service Catalog provisions; read by `aft-account-request-processor` Lambda as `AFT_PROVISIONING_CONCURRENCY` env. |
| `maximum_concurrent_customizations` | `number` | `5` | no | CONCURRENCY | MaxConcurrency of the Distributed Map in `aft-invoke-customizations` SFN. |
| `aft_codebuild_compute_type` | `string` | `"BUILD_GENERAL1_MEDIUM"` | no | BUILD | CodeBuild compute tier for all AFT build projects. |
| `global_codebuild_timeout` | `number` | `60` | no | BUILD | Build timeout (minutes) for all AFT CodeBuild projects. |
| `cloudwatch_log_group_retention` | `string` | `"0"` | no | OBSERVABILITY | Days to retain Lambda CloudWatch logs. `"0"` = never expire. |
| `cloudwatch_log_group_enable_cmk_encryption` | `bool` | `false` | no | ENCRYPTION | Encrypt CloudWatch logs with the AFT CMK (extra cost) vs AWS-managed. |
| `sns_topic_enable_cmk_encryption` | `bool` | `false` | no | ENCRYPTION | Encrypt AFT SNS topics with the AFT CMK (extra cost). |
| `backup_recovery_point_retention` | `number` | `null` | no | BACKEND | AWS Backup retention days for AFT DDB tables. `null` = never expire. |
| `aft_backend_bucket_access_logs_object_expiration_days` | `number` | `365` | no | BACKEND | S3 lifecycle expiration on the backend access-logs bucket. |
| `sfn_s3_bucket_object_expiration_days` | `number` | `90` | no | BACKEND | S3 lifecycle expiration on the customizations-pipeline bucket (`sfn/` prefix). |
| `log_archive_bucket_object_expiration_days` | `number` | `365` | no | BACKEND | S3 lifecycle expiration on the log-archive CloudTrail bucket. |
| `tags` | `map(any)` | `null` | no | TAG | Map of tags applied to AFT-managed resources. |

### 3.1 Required inputs (5)

`ct_management_account_id`, `ct_home_region`, `aft_management_account_id`, `log_archive_account_id`, `audit_account_id`.

### 3.2 Sensitive inputs

`terraform_token` — README explicitly notes state may contain it in plaintext.

---

## 4. Feature flags and toggles

Disproportionately important for configurability parity. All default `false` except `aft_metrics_reporting` (default `true`), `aft_enable_vpc` (default `true`), and `aft_vpc_endpoints` (default `true`).

| Variable | Default | Gate for |
|----------|---------|----------|
| `aft_feature_cloudtrail_data_events` | `false` | CloudTrail data-events enablement path in `aft-feature-options` SFN + log-archive bucket policy. |
| `aft_feature_delete_default_vpcs_enabled` | `false` | `aft-delete-default-vpc` Lambda task in `aft-feature-options` SFN (every region). |
| `aft_feature_enterprise_support` | `false` | `aft-enroll-support` Lambda task (AWS Support API); requires payer eligibility. |
| `aft_metrics_reporting` | `true` | Anonymous usage telemetry on every SFN run; `aft_metrics_reporting_uuid` SSM param created when true. |
| `terraform_oidc_integration` | `false` | Injects OIDC `sub` claim condition + HCP provider principal into `AWSAFTAdmin` trust policy. Implies `terraform_distribution` is `tfc` or `tfe`. |
| `aft_enable_vpc` | `true` | Creates AFT VPC + subnets + NAT (vs relying on Lambda without VPC). |
| `aft_vpc_endpoints` | `true` | Creates interface/gateway endpoints inside AFT VPC. |
| `aft_customer_vpc_id` (BYO) | `null` | Non-null disables AFT-managed VPC creation; uses supplied VPC/subnets. |
| `cloudwatch_log_group_enable_cmk_encryption` | `false` | CloudWatch log groups use AFT CMK instead of AWS-managed. |
| `sns_topic_enable_cmk_encryption` | `false` | SNS topics use AFT CMK instead of AWS-managed. |

Note: there is no `aft_feature_hcp_oidc` variable in the README input list, despite the README prose referencing it in `terraform_oidc_aws_audience` / `terraform_oidc_hostname` descriptions. `terraform_oidc_integration` is the live toggle. **Flag this ambiguity in the audit.**

---

## 5. Outputs

59 outputs. Source derivation from `outputs.tf`: outputs whose value is `var.x` are pass-throughs of the matching input; outputs whose value is `module.<m>.<attr>` are sourced from the named submodule.

### 5.1 Pass-through (input echo) outputs

Source: `value = var.<same>`. These simply expose the input for downstream convenience.

| Output | Source var |
|--------|-----------|
| `ct_management_account_id` | `var.ct_management_account_id` |
| `log_archive_account_id` | `var.log_archive_account_id` |
| `audit_account_id` | `var.audit_account_id` |
| `aft_management_account_id` | `var.aft_management_account_id` |
| `ct_home_region` | `var.ct_home_region` |
| `cloudwatch_log_group_retention` | `var.cloudwatch_log_group_retention` |
| `backup_recovery_point_retention` | `var.backup_recovery_point_retention` |
| `maximum_concurrent_customizations` | `var.maximum_concurrent_customizations` |
| `aft_feature_cloudtrail_data_events` | `var.aft_feature_cloudtrail_data_events` |
| `aft_feature_enterprise_support` | `var.aft_feature_enterprise_support` |
| `aft_feature_delete_default_vpcs_enabled` | `var.aft_feature_delete_default_vpcs_enabled` |
| `vcs_provider` | `var.vcs_provider` |
| `github_enterprise_url` | `var.github_enterprise_url` |
| `gitlab_selfmanaged_url` | `var.gitlab_selfmanaged_url` |
| `account_request_repo_name` | `var.account_request_repo_name` |
| `account_request_repo_branch` | `var.account_request_repo_branch` |
| `global_customizations_repo_name` | `var.global_customizations_repo_name` |
| `global_customizations_repo_branch` | `var.global_customizations_repo_branch` |
| `account_customizations_repo_name` | `var.account_customizations_repo_name` |
| `account_customizations_repo_branch` | `var.account_customizations_repo_branch` |
| `account_provisioning_customizations_repo_name` | `var.account_provisioning_customizations_repo_name` |
| `account_provisioning_customizations_repo_branch` | `var.account_provisioning_customizations_repo_branch` |
| `terraform_version` | `var.terraform_version` |
| `terraform_distribution` | `var.terraform_distribution` |
| `tf_backend_secondary_region` | `var.tf_backend_secondary_region` |
| `terraform_org_name` | `var.terraform_org_name` |
| `terraform_api_endpoint` | `var.terraform_api_endpoint` |
| `aft_vpc_cidr` | `var.aft_vpc_cidr` |
| `aft_vpc_private_subnet_01_cidr` | `var.aft_vpc_private_subnet_01_cidr` |
| `aft_vpc_private_subnet_02_cidr` | `var.aft_vpc_private_subnet_02_cidr` |
| `aft_vpc_public_subnet_01_cidr` | `var.aft_vpc_public_subnet_01_cidr` |
| `aft_vpc_public_subnet_02_cidr` | `var.aft_vpc_public_subnet_02_cidr` |

### 5.2 Module-sourced outputs

| Output | Source module attribute | Summary |
|--------|-------------------------|---------|
| `aft_primary_backend_bucket_id` | `module.aft_backend.bucket_id` | Primary state S3 bucket (aft-mgmt). |
| `aft_secondary_backend_bucket_id` | `module.aft_backend.secondary_bucket_id` | Secondary replica bucket (if `tf_backend_secondary_region` set). |
| `aft_access_logs_primary_backend_bucket_id` | `module.aft_backend.access_logs_bucket_id` | S3 access-logs bucket for backend bucket. |
| `aft_backend_lock_table_name` | `module.aft_backend.table_id` | DynamoDB lock table for Terraform state. |
| `aft_backend_primary_kms_key_id` | `module.aft_backend.kms_key_id` | KMS CMK id for primary-region state bucket. |
| `aft_backend_primary_kms_key_alias_arn` | `module.aft_backend.kms_key_alias_arn` | KMS alias ARN, primary. |
| `aft_backend_secondary_kms_key_id` | `module.aft_backend.secondary_kms_key_id` | KMS CMK id for secondary-region state bucket. |
| `aft_backend_secondary_kms_key_alias_arn` | `module.aft_backend.secondary_kms_key_alias_arn` | KMS alias ARN, secondary. |
| `aft_admin_role_arn` | `module.aft_iam_roles.aft_admin_role_arn` | `AWSAFTAdmin` role ARN in aft-mgmt. |
| `aft_ct_management_exec_role_arn` | `module.aft_iam_roles.ct_management_exec_role_arn` | `AWSAFTExecution` in ct-management. |
| `aft_log_archive_exec_role_arn` | `module.aft_iam_roles.log_archive_exec_role_arn` | `AWSAFTExecution` in log-archive. |
| `aft_audit_exec_role_arn` | `module.aft_iam_roles.audit_exec_role_arn` | `AWSAFTExecution` in audit. |
| `aft_exec_role_arn` | `module.aft_iam_roles.aft_exec_role_arn` | `AWSAFTExecution` in aft-management. |
| `aft_request_table_name` | `module.aft_account_request_framework.request_table_name` | `aft-request` DDB table — the request inbox. |
| `aft_request_audit_table_name` | `module.aft_account_request_framework.request_audit_table_name` | `aft-request-audit` DDB table. |
| `aft_request_metadata_table_name` | `module.aft_account_request_framework.request_metadata_table_name` | `aft-request-metadata` DDB table. |
| `aft_controltower_events_table_name` | `module.aft_account_request_framework.controltower_events_table_name` | `aft-controltower-events` DDB table. |
| `aft_kms_key_id` | `module.aft_account_request_framework.aft_kms_key_id` | Primary AFT CMK (encrypts DDB/SNS/CodeBuild artefacts). |
| `aft_kms_key_alias_arn` | `module.aft_account_request_framework.aft_kms_key_alias_arn` | Alias for primary AFT CMK. |
| `aft_account_provisioning_framework_step_function_arn` | `module.aft_account_provisioning_framework.state_machine_arn` | `aft-account-provisioning-framework` SFN ARN. |
| `aft_invoke_customizations_step_function_arn` | `module.aft_customizations.state_machine_arn` | `aft-invoke-customizations` SFN ARN. |
| `aft_features_step_function_arn` | `module.aft_feature_options.state_machine_arn` | `aft-feature-options` SFN ARN. |
| `aft_sns_topic_arn` | `module.aft_account_request_framework.aft_sns_topic_arn` | `aft-notifications` SNS topic. |
| `aft_failure_sns_topic_arn` | `module.aft_account_request_framework.aft_failure_sns_topic_arn` | `aft-failure-notifications` SNS topic. |

### 5.3 Output gaps vs resources

Notable runtime primitives that exist in the stack but are **not** exposed as root outputs (flag during audit for whether atmos-aft should expose them):

- `aft-account-provisioning-customizations` SFN ARN (customer-owned SFN; only provisioning-framework SFN is exposed).
- `aft-account-request.fifo` SQS queue ARN/URL + its DLQ.
- Custom EventBridge bus `aft-events-from-ct-management` ARN.
- Per-account `${account_id}-customizations-pipeline` ARNs (dynamic, per-account — not addressable from root).
- CodePipeline ARNs for `ct-aft-account-request` and `ct-aft-account-provisioning-customizations`.
- CodeBuild project ARNs (`aft-global-customizations-terraform`, `aft-account-customizations-terraform`, `aft-create-pipeline`, `ct-aft-account-request`, `ct-aft-account-provisioning-customizations`).
- The 6 account-request Lambdas and 3 customization Lambdas.

---

## 6. Counts summary

- Modules: **10** (all local).
- Data sources at root: **4**.
- Inputs: **52**, of which **5 required**, **1 sensitive** (`terraform_token`).
- Outputs: **59** (31 pass-through echoes of inputs, 24 module-sourced, plus 4 derived pass-throughs covered above).
- Feature flags / toggles of interest to parity: **10** (listed in §4).

---

## 7. Notes for the audit

Tracked observations that fed the Phase 2 [`archive/readme-audit.md`](archive/readme-audit.md) (archived) tables without needing to re-read the upstream README:

- The README surfaces `terraform_oidc_integration`, but the descriptions of `terraform_oidc_aws_audience` and `terraform_oidc_hostname` refer to a non-existent `aft_feature_hcp_oidc` variable. Upstream doc bug; atmos-aft should document one toggle name and stick to it.
- Every repo comes in pairs `{repo_name, repo_branch}`. Atmos-aft's factory config likely collapses these into a single object — note the expansion when auditing.
- Outputs are a mix of trivial input echoes and real resource coordinates. Parity only matters for the latter (§5.2). Input-echo outputs are low value; atmos-aft can drop them without loss if the inputs are visible in stack config.
- VPC inputs assume AFT owns the VPC; the BYO-VPC path (`aft_customer_vpc_id`) is "new deployments only" in upstream. Atmos-aft may reasonably drop the AFT-managed VPC entirely and always BYO — flag as scope cut.
- The fact that `terraform_token` is an input but also lives in SSM as SecureString means the audit must cover both surfaces: config plane input + runtime retrieval.
