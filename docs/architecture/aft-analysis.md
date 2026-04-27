# AFT Reference Analysis

Ground-truth analysis of the upstream `aws-ia/terraform-aws-control_tower_account_factory` (AFT) reference checkout under `./reference/aft`. All file references are relative to that path unless otherwise stated.

This document is the input spec for building an Atmos + GitHub Actions replacement. It describes what AFT does, not yet how we replace it.

---

## 1. Top-level modules

AFT is orchestrated from `main.tf` in the repo root (`main.tf:1-301`). It instantiates ten child modules that can be grouped into five concerns: packaging, account request pipeline, account provisioning pipeline, per-account customizations pipeline, and shared platform primitives (backend, IAM, Lambda layer, SSM). Cross-module wiring is almost entirely through SSM parameters (section 4) and hard-coded role names from `locals.tf`.

`locals.tf:1-72` defines the canonical names the whole system reuses: the four Step Functions (`aft-account-provisioning-framework`, `aft-account-provisioning-customizations`, `aft-invoke-customizations`, `aft-feature-options`), the IAM roles (`AWSAFTExecution`, `AWSAFTAdmin`, `AWSAFTService`) and the fixed STS session name `AWSAFT-Session`.

`providers.tf:1-57` declares five AWS provider aliases. The default provider targets the CT management account; four aliases (`aft_management`, `audit`, `log_archive`, `tf_backend_secondary_region`) each assume `AWSControlTowerExecution` in the respective account. This is the only place in the entire stack where `AWSControlTowerExecution` is used directly - every runtime path uses the `AWSAFTAdmin`/`AWSAFTExecution` chain established in section 5.

### 1.1 `packaging` (`main.tf:4-6`, `modules/packaging/`)

Zips the Lambda source trees under `src/aft_lambda/` into deployment archives that the other modules consume via `local.archive_path`. Pure build-time; no AWS resources.

### 1.2 `aft_account_provisioning_framework` (`main.tf:8-37`)

Owns the SFN that runs immediately after Control Tower finishes vending an account. Creates four Lambdas (`create_role`, `tag_account`, `persist_metadata`, `account_metadata_ssm` - `modules/aft-account-provisioning-framework/lambda.tf:1-123`) and the SFN definition at `modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json:1-182`. Covered in detail in section 2.

### 1.3 `aft_account_request_framework` (`main.tf:39-65`)

The ingestion and routing layer. Owns the four DynamoDB tables, SQS queue + DLQ, SNS topics, EventBridge bus/rules, and six Lambdas that together turn a write to the `aft-request` table into either an SQS message for Service Catalog or a direct Step Functions invocation. Detailed in section 4.

### 1.4 `aft_backend` (`main.tf:67-77`, `modules/aft-backend/main.tf:1-456`)

Terraform state infrastructure. Primary S3 bucket `aft-backend-${aft_mgmt_id}-primary-region`, optional secondary bucket with S3 replication for DR, a DynamoDB lock table `aft-backend-${aft_mgmt_id}`, per-region KMS keys (`enable_key_rotation = true`, 30-day deletion window), and a separate access-logs bucket. This is the state backend used by *every* Terraform run in the system: bootstrap, customer repos, and per-account customizations. Detailed in section 7.

### 1.5 `aft_code_repositories` (`main.tf:79-111`)

Hosts the four customer-facing repositories and the two CodePipelines that watch them. Switches between CodeCommit and CodeConnections (GitHub / GitHub Enterprise / Bitbucket / GitLab / GitLab self-managed / Azure DevOps) based on `var.vcs_provider`. Detailed in sections 3 and 6.

### 1.6 `aft_customizations` (`main.tf:113-151`)

The per-account customization runtime. Owns `aft-invoke-customizations` SFN, three Lambdas (`aft-customizations-identify-targets`, `aft-customizations-execute-pipeline`, `aft-customizations-get-pipeline-executions`), three CodeBuild projects (`aft-global-customizations-terraform`, `aft-account-customizations-terraform`, `aft-create-pipeline`), and the S3 bucket `aft-customizations-pipeline-${aft_mgmt_account_id}`. Detailed in section 3.

### 1.7 `aft_feature_options` (`main.tf:153-183`, `modules/aft-feature-options/`)

Optional post-provisioning steps: delete default VPCs, enroll the new account in Enterprise Support, enable CloudTrail org-wide logging. Three Lambdas (`lambda.tf`) plus the `aft-feature-options` SFN (`states/aft_features.asl.json`). Each step is gated on a boolean input variable. Also creates the central CloudTrail log bucket `aws-aft-logs-${log_archive_account_id}-${region}` in the log-archive account (`s3.tf`).

### 1.8 `aft_iam_roles` (`main.tf:185-200`, `modules/aft-iam-roles/iam.tf:1-107`)

The trust-policy backbone. Creates `AWSAFTAdmin` in aft-management, then fan-outs via two submodules (`admin-role/`, `service-role/`) into ct-management, log-archive, audit, and aft-management to create `AWSAFTExecution` and `AWSAFTService` in each. Detailed in section 5.

### 1.9 `aft_lambda_layer` (`main.tf:202-226`)

Builds the `aft-common` Python Lambda layer via a CodeBuild project (`modules/aft-lambda-layer/codebuild.tf`) that pip-installs dependencies and uploads the layer ZIP. Triggered eagerly by a `data.aws_lambda_invocation` call on a trigger Lambda (`modules/aft-lambda-layer/lambda.tf`) so that the layer exists before any other module that depends on it is applied. Python version is driven by `var.aft_lambda_layer_python_version`.

### 1.10 `aft_ssm_parameters` (`main.tf:228-301`, `modules/aft-ssm-parameters/ssm.tf:1-409`)

Publishes roughly fifty SSM parameters under `/aft/config/*`, `/aft/account/*`, `/aft/resources/*` that act as the cross-component configuration plane. Terraform version, module references, region, VCS provider, CloudWatch log retention, feature toggles, backend names, and the `terraform_token` (SecureString) all land here. Every CodeBuild buildspec in the system reads these at runtime rather than receiving them as environment variables at plan time. This is the loose coupling that lets the four customer repos stay decoupled from AFT's Terraform.

---

## 2. Account provisioning lifecycle

The end-to-end lifecycle from `aft-request` DDB write through to a green customization pipeline has five logical phases.

### Phase A: Request ingestion

1. **Customer Terraform** in `aft-account-request` writes a `aws_dynamodb_table_item` to the `aft-request` table (`sources/aft-customizations-repos/aft-account-request/terraform/modules/aft-account-request/ddb.tf`). The request shape is defined by example in `sources/aft-customizations-repos/aft-account-request/examples/account-request.tf` - `control_tower_parameters` (AccountEmail, AccountName, ManagedOrganizationalUnit, SSOUser*), `account_tags`, `change_management_parameters`, `custom_fields`, `account_customizations_name`.
2. The DDB **stream** on `aft-request` (`modules/aft-account-request-framework/ddb.tf:1-128`, `StreamViewType = NEW_AND_OLD_IMAGES`) fires into `aft-account-request-action-trigger` Lambda (`modules/aft-account-request-framework/lambda.tf:1-258`).
3. The handler (`src/aft_lambda/aft_account_request_framework/aft_account_request_action_trigger.py:24-44`) delegates to `AccountRequestRecordHandler.process_request()` in `sources/aft-lambda-layer/aft_common/account_request_record_handler.py:115-148`. Routing rules:
   - `REMOVE` → invoke `aft-cleanup-resources` Lambda.
   - `INSERT` with no provisioned product → enqueue SQS with `operation=ADD`.
   - `INSERT` for an existing CT account → invoke provisioning SFN directly (import path).
   - `MODIFY` with `control_tower_parameters` changed → enqueue SQS with `operation=UPDATE`.
   - `MODIFY` without CT change → invoke provisioning SFN directly (customization-only).
   - Shared-account (ct-management/log-archive/audit) customization request → invoke provisioning SFN directly.

### Phase B: Service Catalog provisioning (new/modified CT params only)

4. **`aft-account-request-processor`** Lambda runs on a 5-minute EventBridge schedule (`modules/aft-account-request-framework/eventbridge.tf:1-74`). Its handler (`src/aft_lambda/aft_account_request_framework/aft_account_request_processor.py:37-133`) drains up to `AFT_PROVISIONING_CONCURRENCY` messages from `aft-account-request.fifo`, calls `AccountRequest.create_new_account()` or `update_existing_account()` - which invoke AWS Service Catalog's Account Factory product - and deletes the SQS message on success. CT param validation (`new_ct_request_is_valid`, `modify_ct_request_is_valid`) runs before provisioning.
5. Control Tower runs its own state machine and ultimately emits a `CreateManagedAccount` or `UpdateManagedAccount` event on the ct-management account default bus.

### Phase C: CT event crossing

6. A rule on ct-management's default bus forwards those two event names to the **custom bus `aft-events-from-ct-management`** in aft-management (`modules/aft-account-request-framework/eventbridge.tf:1-74`). A resource-based policy on the custom bus grants ct-management `PutEvents`.
7. A rule on the custom bus invokes `aft-invoke-aft-account-provisioning-framework` Lambda. Its handler (`src/aft_lambda/aft_account_request_framework/aft_invoke_aft_account_provisioning_framework.py:35-116`):
   - Extracts `account_id` from `detail.serviceEventDetails.createManagedAccountStatus.account.accountId` (or `updateManagedAccountStatus`).
   - Resolves the account email via `OrganizationsAgent.get_account_email_from_id`.
   - Looks up the full DDB request row by email (PK).
   - Builds an `AftInvokeAccountCustomizationPayload` via `build_account_customization_payload` and starts the `aft-account-provisioning-framework` SFN (name from SSM `SSM_PARAM_AFT_SFN_NAME`).

### Phase D: Provisioning framework SFN

8. **`aft-account-provisioning-framework`** (`modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json:1-182`) runs in the aft-management account and orchestrates:
   - `persist_metadata` - writes the account into the `aft-request-metadata` DDB table.
   - `create_role` - creates `AWSAFTExecution` in the newly vended account (retry 5x, 60s interval, backoff 1.5x - the key guard against IAM eventual consistency).
   - `tag_account` - applies `account_tags` via Organizations.
   - `account_metadata_ssm` - writes `/aft/account/<name>/account-id` and related SSM params.
   - `aft_features` - child SFN `aft-feature-options` with `startExecution.sync:2` integration (delete default VPCs, enroll support, enable CloudTrail).
   - `account_provisioning_customizations` - child SFN `aft-account-provisioning-customizations` (customer-owned, defined in `sources/aft-customizations-repos/aft-account-provisioning-customizations/terraform/states/customizations.asl.json`; default is a single `Pass` state), also `startExecution.sync:2`. Errors caught so a customer-supplied SFN error does not abort.
   - Choice `run_create_pipeline?` - if the per-account pipeline does not yet exist, run CodeBuild `aft-create-pipeline` synchronously with `VENDED_ACCOUNT_ID` env override.
   - `notify_success` - publish to `aft-notifications`.

### Phase E: Customizations pipeline

9. The per-account pipeline `${vended_account_id}-customizations-pipeline` is created by the CodeBuild project `aft-create-pipeline` (`modules/aft-customizations/codebuild.tf:1-265`). The pipeline definition itself is generated from templates in `sources/aft-customizations-common/templates/customizations_pipeline/codepipeline.tf:1-227` - a three-stage pipeline:
   - **Source**: two CodeCommit or CodeConnections source actions (`aft-global-customizations`, `aft-account-customizations`).
   - **Global-Customizations**: CodeBuild `aft-global-customizations-terraform` with env `VENDED_ACCOUNT_ID`.
   - **Account-Customizations**: CodeBuild `aft-account-customizations-terraform` with env `VENDED_ACCOUNT_ID`.
10. Ongoing customizations are driven by the `aft-invoke-customizations` SFN (`modules/aft-customizations/states/invoke_customizations.asl.json:1-137`). It identifies target accounts (include/exclude by all/core/ous/tags/accounts, `sources/aft-lambda-layer/aft_common/customizations.py:32-240`), writes the target list to S3, then uses a **distributed Map** (`arn:aws:states:::s3:getObject` reader, `MaxConcurrency = ${maximum_concurrent_customizations}`) to fan out - each iteration starts the provisioning SFN sync. After the map, it polls pipeline executions on a 30-second loop until `Below max? = true`, then kicks `aft-customizations-execute-pipeline` for queued accounts.

### Shared-account path

Shared accounts (`ct-management`, `log-archive`, `audit`) cannot be vended - they exist before AFT. `shared_account_request` in `aft_common.shared_account` treats any request matching those names as a customization-only path: handled directly by `handle_customization_request` which skips Service Catalog and jumps to the provisioning SFN.

---

## 3. CodeBuild projects and CodePipelines

### 3.1 CodeBuild projects (five)

1. **`ct-aft-account-request`** - `modules/aft-code-repositories/codebuild.tf:1-133`. Buildspec `modules/aft-code-repositories/buildspecs/ct-aft-account-request.yml:1-119`. Reads SSM (`terraform_version`, `terraform_distribution`, `aft_execution_role_arn`, `aft_admin_role_arn`), assumes `AWSAFTAdmin`, renders `backend.jinja`/`aft-providers.jinja`, runs `terraform init` + `apply`. TF S3 key: `account-request/terraform.tfstate`. Input: the customer `aft-account-request` repo via CodePipeline source action.

2. **`ct-aft-account-provisioning-customizations`** - same module. Buildspec `modules/aft-code-repositories/buildspecs/ct-aft-account-provisioning-customizations.yml:1-120`. Identical shape; TF S3 key: `account-provisioning-customizations/terraform.tfstate`. Input: the customer `aft-account-provisioning-customizations` repo.

3. **`aft-global-customizations-terraform`** - `modules/aft-customizations/codebuild.tf:1-265`. CODEPIPELINE source, CODEPIPELINE artifacts. Image `aws/codebuild/amazonlinux2-x86_64-standard:5.0`. Buildspec `modules/aft-customizations/buildspecs/aft-global-customizations-terraform.yml`. Looks up customization directory from `aft-request-metadata` DDB by `VENDED_ACCOUNT_ID`; renders templates with `target_admin_role_arn=AWSAFTExecution in $VENDED_ACCOUNT_ID`; runs `pre-api-helpers.sh` with profile `aft-target`, `terraform apply` with profile `aft-management-admin`, then `post-api-helpers.sh`. TF S3 key: `$VENDED_ACCOUNT_ID-aft-global-customizations/terraform.tfstate`.

4. **`aft-account-customizations-terraform`** - same module, CODEPIPELINE source/artifacts. Buildspec `modules/aft-customizations/buildspecs/aft-account-customizations-terraform.yml:1-190`. Short-circuits if no customization directory is found for the account; otherwise same template/render/apply pattern. TF S3 key: `$VENDED_ACCOUNT_ID-aft-account-customizations/terraform.tfstate`.

5. **`aft-create-pipeline`** - same module. NO_SOURCE, NO_ARTIFACTS. Triggered synchronously from the provisioning SFN (Phase D step 8) with `ACCOUNT_ID=TBD` overridden to the vended account's ID at runtime. Buildspec `modules/aft-customizations/buildspecs/aft-create-pipeline.yml` reads SSM for TF backend + module source, clones `aws-aft-core-framework`, renders the `customizations_pipeline` Terraform templates, and runs `terraform apply -var="account_id=$VENDED_ACCOUNT_ID"` via profile `aft-management-admin`. This is the project that materializes the per-account CodePipeline.

Plus a sixth build-time-only CodeBuild project in `modules/aft-lambda-layer/codebuild.tf` that builds the `aft-common` Lambda layer.

All five runtime CodeBuild projects use service role `aft_codebuild_customizations_role` (or the repo-level equivalent in `aft-code-repositories`) and are encrypted with `aft_kms_key_arn`.

### 3.2 CodePipelines (four static + one dynamic-per-account)

All four static pipelines live in `modules/aft-code-repositories/codepipeline.tf:1-356`. Two names are produced regardless of VCS:

1. **`ct-aft-account-request`** - triggered by either a CodeCommit state-change EventBridge rule or CodeConnections `DetectChanges = true`. Stages: Source (customer repo) → Build (`ct-aft-account-request` CodeBuild).
2. **`ct-aft-account-provisioning-customizations`** - triggered similarly from the customer `aft-account-provisioning-customizations` repo. Stages: Source → Build.

The two conditional resource blocks `codecommit_account_request`/`codeconnections_account_request` and `codecommit_account_provisioning_customizations`/`codeconnections_account_provisioning_customizations` are selected via `local.vcs` dispatch in `modules/aft-code-repositories/locals.tf`.

The remaining two static pipelines that a naive read of `main.tf` might expect (for the global/account customizations repos) do **not** exist at this layer. Those repos are consumed only by the per-account dynamic pipeline.

**Dynamic per-account pipeline: `${account_id}-customizations-pipeline`** (`sources/aft-customizations-common/templates/customizations_pipeline/codepipeline.tf:1-227`). Created by `aft-create-pipeline` CodeBuild during phase D. Stages:
- Source: two source actions - `aft-global-customizations` + `aft-account-customizations` - from CodeCommit or CodeConnections depending on `var.vcs_provider`.
- Global-Customizations stage: runs `aft-global-customizations-terraform` with env override `VENDED_ACCOUNT_ID`.
- Account-Customizations stage: runs `aft-account-customizations-terraform` with same env override.

Execution of these pipelines is coordinated by the `aft-invoke-customizations` SFN and its three Lambdas (`identify-targets`, `execute-pipeline`, `get-pipeline-executions`), throttled to `var.maximum_concurrent_customizations`.

---

## 4. State and queue resources

### 4.1 DynamoDB tables (four, in aft-management)

`modules/aft-account-request-framework/ddb.tf:1-128`. All tables: KMS-encrypted with `aft_kms_key_arn`, PITR enabled, billing `PAY_PER_REQUEST`.

| Table | PK | SK | Stream | Purpose |
|-------|----|----|--------|---------|
| `aft-request-metadata` | `id` (email) | - | - | Materialised account metadata (account_id, name, email, OU, tags, customization dir). GSIs on `type` and `email`. Consumed by provisioning SFN + every CodeBuild buildspec. |
| `aft-request` | `id` (email) | - | `NEW_AND_OLD_IMAGES` | The request inbox. Customer repo writes here; stream drives ingestion. |
| `aft-request-audit` | `id` | `timestamp` | `NEW_AND_OLD_IMAGES` | Audit log of every request transition. Fed by `aft-account-request-audit-trigger` Lambda. |
| `aft-controltower-events` | `id` | `time` | `NEW_AND_OLD_IMAGES` | Persisted copy of every CT lifecycle event. Fed by `aft-controltower-event-logger` Lambda. |

Additionally, `modules/aft-backend/main.tf` creates `aft-backend-${aft_mgmt_id}` - the Terraform state lock table (LockID PK). This is *not* part of the request framework; it only serves state coherence.

### 4.2 SQS (aft-management)

`modules/aft-account-request-framework/sqs.tf:1-22`:

- **`aft-account-request.fifo`** - FIFO queue. `visibility_timeout_seconds = 240`. Enforces per-request ordering and provides the throttle point between the DDB-stream handler and Service Catalog. Redrive to DLQ with `maxReceiveCount = 1` (one retry before dead-lettering, because Service Catalog account factory calls are long and expensive to re-run blindly).
- **`aft-account-request-dlq.fifo`** - FIFO DLQ.

### 4.3 SNS (aft-management)

`modules/aft-account-request-framework/sns.tf`:

- **`aft-notifications`** - success/progress SNS topic, published from SFN `notify_success` terminal states.
- **`aft-failure-notifications`** - failure SNS topic, published by `send_lambda_failure_sns_message` (from `aft_common.notifications`, invoked in every Lambda's top-level except block).

Subscribers are not created by AFT - customers attach their own.

### 4.4 Step Functions (four)

All in aft-management.

1. **`aft-account-provisioning-framework`** - `modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json:1-182`. Main orchestrator. Described in section 2, phase D.
2. **`aft-account-provisioning-customizations`** - definition lives in the customer `aft-account-provisioning-customizations` repo (`sources/aft-customizations-repos/aft-account-provisioning-customizations/terraform/states.tf` with `states/customizations.asl.json` as default - a single `Pass` state). Invoked sync from #1. Customer-extensible.
3. **`aft-invoke-customizations`** - `modules/aft-customizations/states/invoke_customizations.asl.json:1-137`. Described in section 2, phase E step 10. Notable: uses a **DISTRIBUTED Map** with an S3-object reader as the iterator - the target-account list is materialised to S3 under `sfn/${execution_id}/target_account_info.json` by `aft-customizations-identify-targets` (`sources/aft-lambda-layer/aft_common/customizations.py:243-262`).
4. **`aft-feature-options`** - `modules/aft-feature-options/states/aft_features.asl.json`. Sequentially: Delete Default VPCs → Enroll Enterprise Support → Enable CloudTrail → Notify Success.

### 4.5 EventBridge

`modules/aft-account-request-framework/eventbridge.tf:1-74`:

- **Custom bus `aft-events-from-ct-management`** - in aft-management, with a resource policy allowing ct-management to `PutEvents`.
- Rule on the custom bus for `CreateManagedAccount` and `UpdateManagedAccount` → `aft-invoke-aft-account-provisioning-framework` Lambda.
- Rule on ct-management's default bus (via `aws.ct_management` provider) mirroring those two event names to the custom bus in aft-management.
- Schedule `aft-lambda-account-request-processor`: `rate(5 minutes)` → `aft-account-request-processor` Lambda.

---

## 5. IAM roles and trust policies

AFT establishes a deliberate three-role chain. No runtime path uses AWS SSO users or `AWSControlTowerExecution` directly; only the bootstrap `providers.tf` does.

### 5.1 The chain

```
caller (Terraform operator or CodeBuild service role in aft-mgmt)
  └─ sts:AssumeRole → AWSAFTAdmin  (in aft-management, session = AWSAFT-Session)
       └─ sts:AssumeRole → AWSAFTExecution   (in any target account)
                           AWSAFTService     (in any target account)
```

`locals.tf` pins the session name to `AWSAFT-Session` - this is load-bearing because trust policies reference the resulting assumed-role ARN.

### 5.2 `AWSAFTAdmin` - `modules/aft-iam-roles/iam.tf:1-107`

Lives in aft-management only.

- **Trust**: `modules/aft-iam-roles/iam/aft_admin_role_trust_policy.tpl`. Allows the aft-management root principal (so any identity in aft-mgmt that has `sts:AssumeRole` on this role) plus, optionally, HCP Terraform's OIDC provider. The OIDC condition is: `${terraform_oidc_hostname}:sub = organization:${org}:project:${project}:workspace:*:run_phase:*`. This is the path used when `terraform_distribution = tfc | tfe` so HCP workspaces can federate in without long-lived keys.
- **Permissions**: `modules/aft-iam-roles/iam/aft_admin_role_policy.tpl`. `sts:AssumeRole` on `arn:${partition}:iam::*:role/AWSAFTExecution` and `arn:${partition}:iam::*:role/AWSAFTService` across all accounts.

### 5.3 `AWSAFTExecution` - `modules/aft-iam-roles/admin-role/main.tf`

Created in ct-management, log-archive, audit, and aft-management at bootstrap time by the `admin-role` submodule. Created in vended accounts at runtime by the `create_role` Lambda during SFN phase D.

- **Trust**: `modules/aft-iam-roles/admin-role/trust_policy.tpl`. Allows both:
  - The role principal `arn:aws:iam::${aft_mgmt}:role/AWSAFTAdmin` (for fresh `AssumeRole` calls).
  - The assumed-role principal `arn:aws:sts::${aft_mgmt}:assumed-role/AWSAFTAdmin/AWSAFT-Session` (for chained calls from already-assumed sessions).
- **Permissions**: `AdministratorAccess` managed policy.

The assumed-role ARN is materialised in `modules/aft-iam-roles/locals.tf` as `aft_admin_assumed_role_arn = arn:${partition}:sts::${aft_mgmt}:assumed-role/AWSAFTAdmin/AWSAFT-Session` and is the reason the session name is pinned.

### 5.4 `AWSAFTService` - `modules/aft-iam-roles/service-role/main.tf`

Same shape and trust as `AWSAFTExecution`, different name. Used by Service Catalog / Control Tower automations (portfolio share) where a second, distinct role identity is needed. Also `AdministratorAccess`.

### 5.5 Per-Lambda execution roles

`modules/aft-account-request-framework/iam.tf:1-204` and sibling `iam.tf` files in the other modules. Every Lambda gets its own role with scoped permissions assembled from `iam/trust-policies/*.tpl` (`lambda.tpl`, `events.tpl`, `backup.tpl`) and `iam/role-policies/*.tpl`. No role reuse across Lambdas.

### 5.6 CodeBuild service roles

`aft_codebuild_customizations_role` (in `modules/aft-customizations/iam.tf`) and the paired role in `aft-code-repositories`. Both are permitted to `AssumeRole AWSAFTAdmin` - this is how buildspecs bootstrap into the chain using the line `aws sts assume-role --role-arn $AFT_ADMIN_ROLE_ARN --role-session-name $SESSION_NAME`.

---

## 6. Customer repositories

Four customer repos. Three of them (`aft-account-request`, `aft-account-provisioning-customizations`, `aft-global-customizations` stub, `aft-account-customizations` stub) have example bodies under `sources/aft-customizations-repos/`. AFT creates the empty versions of them when `vcs_provider = codecommit` (`modules/aft-code-repositories/codecommit.tf`); for every other VCS the customer pre-creates them and points AFT at them via CodeConnections.

### 6.1 `aft-account-request`

- **Purpose**: the source of truth for which accounts exist and what they look like.
- **Consumer**: `ct-aft-account-request` CodePipeline → CodeBuild. That build runs `terraform apply` whose effect is writing/updating rows in the `aft-request` DDB table.
- **State**: S3 key `account-request/terraform.tfstate` in the aft-management backend (section 7).
- **Modules**: `sources/aft-customizations-repos/aft-account-request/terraform/modules/aft-account-request/` - the `aft-account-request` module exposes a `control_tower_parameters` input and writes `aws_dynamodb_table_item` rows. Example: `.../examples/account-request.tf`.
- **Templating**: `aft-providers.jinja` and `backend.jinja` are rendered at build time (`ct-aft-account-request.yml`), with `assume_role.role_arn = {{ aft_admin_role_arn }}`.

### 6.2 `aft-account-provisioning-customizations`

- **Purpose**: customer-defined customization SFN that runs inside the provisioning framework (phase D step 8).
- **Consumer**: `ct-aft-account-provisioning-customizations` CodePipeline → CodeBuild. Runs `terraform apply`; one resource written is the `aft-account-provisioning-customizations` SFN definition.
- **State**: S3 key `account-provisioning-customizations/terraform.tfstate` in the aft-management backend.
- **Default SFN**: `sources/aft-customizations-repos/aft-account-provisioning-customizations/terraform/states/customizations.asl.json` - a single `Pass` state. Customers extend this with Lambda tasks, manual approvals, etc.

### 6.3 `aft-global-customizations`

- **Purpose**: Terraform applied to *every* AFT-managed account.
- **Consumer**: the Source stage of each per-account `${account_id}-customizations-pipeline`; then the `aft-global-customizations-terraform` CodeBuild runs against it with `VENDED_ACCOUNT_ID` set.
- **State**: S3 key `$VENDED_ACCOUNT_ID-aft-global-customizations/terraform.tfstate`.
- **Structure**: expected layout includes `terraform/` (always applied), `api_helpers/pre-api-helpers.sh`, `api_helpers/post-api-helpers.sh`.

### 6.4 `aft-account-customizations`

- **Purpose**: Terraform applied only to accounts that request a specific customization directory (by `account_customizations_name` in the request).
- **Consumer**: the Source stage of each per-account pipeline; `aft-account-customizations-terraform` CodeBuild.
- **State**: S3 key `$VENDED_ACCOUNT_ID-aft-account-customizations/terraform.tfstate`.
- **Structure**: `<customization_name>/terraform/` + `<customization_name>/api_helpers/` per named bundle. The buildspec (`aft-account-customizations-terraform.yml:1-190`) no-ops if the named directory is absent.

### 6.5 Templating pattern

Across all four repos, two Jinja files are the integration seam:

- **`backend.jinja`** - selects S3 (distribution `oss`) vs HCP remote (`tfc`/`tfe`). Variables: `tf_distribution_type`, `bucket`, `key`, `region`, `dynamodb_table`, `kms_key_id`, or `hostname`, `organization`, `workspaces.name`.
- **`aft-providers.jinja`** - provider blocks with `assume_role { role_arn = <rendered> }`. Roles differ by context:
  - customer-repo builds → `{{ aft_admin_role_arn }}` (cross-account into the vended account via chain).
  - customizations builds → `{{ target_admin_role_arn }}` = `AWSAFTExecution` in `$VENDED_ACCOUNT_ID`, via the profile `aft-target` configured in the buildspec.

Profiles `aft-management-admin`, `aft-target`, and `aft-management` in the buildspecs map to the corresponding `AssumeRole` chains - this is how a single CodeBuild container spans aft-mgmt (for state) and the vended account (for resources).

---

## 7. Terraform state backends

`modules/aft-backend/main.tf:1-456`. Created in aft-management via `provider aws.aft_management`. Two backend modes, toggled by `var.terraform_distribution`:

### 7.1 OSS mode (S3 + DynamoDB)

- **Primary bucket**: `aft-backend-${aft_mgmt_id}-primary-region`. Versioning on. Encrypted with a dedicated KMS key in the primary region. Public access blocked. Server access logs land in a separate access-logs bucket.
- **Secondary bucket** (optional, `var.aft_backend_bucket_access_logs_object_lock` / `var.aft_terraform_distribution` combinations): `aft-backend-${aft_mgmt_id}-secondary-region`, fed by S3 replication for DR. Uses a second KMS key in the secondary region.
- **Lock table**: DynamoDB `aft-backend-${aft_mgmt_id}` with PK `LockID`, `PAY_PER_REQUEST`, KMS-encrypted, PITR on.
- **KMS**: one CMK per region, `enable_key_rotation = true`, `deletion_window_in_days = 30`, aliases `alias/aft-backend-${aft_mgmt_id}-kms-key(-replica)`.
- **Access logs**: separate bucket for S3 server access logs, with its own lifecycle rule (`var.log_archive_bucket_object_lock_enabled` optional).

### 7.2 HCP Terraform mode (`terraform_distribution = tfc | tfe`)

- State is stored in HCP workspaces, federated via OIDC (see `AWSAFTAdmin` trust policy above).
- Per-repo workspace naming is templated in `backend.jinja`.
- The backend module still creates the OSS infra if `var.terraform_distribution = oss`; switching modes at runtime is not supported.

### 7.3 State keys used across the system

| State key | Owner |
|-----------|-------|
| `aft-backend/terraform.tfstate` | bootstrap (AFT root module itself) |
| `account-request/terraform.tfstate` | `ct-aft-account-request` CodeBuild |
| `account-provisioning-customizations/terraform.tfstate` | `ct-aft-account-provisioning-customizations` CodeBuild |
| `$VENDED_ACCOUNT_ID-aft-global-customizations/terraform.tfstate` | per-account pipeline, global stage |
| `$VENDED_ACCOUNT_ID-aft-account-customizations/terraform.tfstate` | per-account pipeline, account stage |
| `${vended_account_id}-customizations-pipeline/terraform.tfstate` (default `aft-create-pipeline` convention) | `aft-create-pipeline` CodeBuild |

All keys share the same bucket and lock table. The DDB lock table is the only coordination point for concurrent Terraform runs across the entire system.

---

## Cross-cutting observations

Points that surprised me while reading, flagged for the GHA replacement design:

- **The DDB stream on `aft-request` is the system's single event source.** Every runtime path - new account, customization-only, CT-param update, delete - fans out from `aft-account-request-action-trigger`. Replacing this with a GHA `workflow_run` + OIDC pattern means picking whether request state lives in Git (PRs), a shared DDB we keep, or GH issue/project state.
- **Per-account CodePipelines are materialised at runtime**, not declared up-front. `aft-create-pipeline` CodeBuild renders a Terraform template and `apply`s it during the provisioning SFN. In GHA terms the equivalent is a workflow that generates a per-account reusable workflow or uses matrix dispatch.
- **The three-role chain is load-bearing.** Trust policies reference `assumed-role/AWSAFTAdmin/AWSAFT-Session` literally. Any replacement that swaps the chain for GHA OIDC must re-template those trust policies (probably cleanly, but it's the touchpoint).
- **SSM parameters are the config plane.** ~50 `/aft/...` keys. CodeBuild buildspecs fetch them at runtime. Replacement can collapse these into Atmos stack config - but cross-account reads still need some runtime lookup (SSM stays viable; Parameter Store is cheap and already in every account).
- **Jinja-templated backend + providers.** This is how AFT sidesteps the fact that Terraform can't take `role_arn` from a variable at backend-init time. Atmos has native per-stack backend rendering that removes the need for Jinja in customer repos.
- **Customer-owned `aft-account-provisioning-customizations` SFN** is the one extension point customers use for approvals/ServiceNow/compliance gating mid-provisioning. The GHA equivalent has to be equally pluggable - probably a named workflow that the orchestrator calls via `workflow_call`.
- **Feature options (VPC/support/CloudTrail) run as a child SFN.** In GHA these are three independent reusable workflows gated by inputs - natural fit.
- **The Distributed Map in `aft-invoke-customizations`** using S3 as the iterator is how AFT fans out to hundreds of accounts without SFN state size limits. GHA's matrix has its own limits (256 jobs per matrix); the replacement will need chunked dispatch or self-hosted runner fan-out.
- **Service Catalog Account Factory is the one component with no GHA analogue.** It is called from the processor Lambda. The replacement either keeps calling Service Catalog from a GHA-invoked Lambda or assumes AFT is only used where CT account vending already happens out-of-band.
