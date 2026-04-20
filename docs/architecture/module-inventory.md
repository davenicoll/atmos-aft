# Cloudposse Module Inventory for the AFT Replacement

Working doc for Phase 1 (design-only). Maps every AWS resource that AWS's Account Factory for Terraform (AFT) stands up to a Cloudposse `terraform-aws-*` module where one exists, and calls out where we should drop the functionality entirely, fall back to a non-Cloudposse community module, or write vanilla Terraform. Every row is clickable — verify before use. Versions were the latest release tag as of 2026-04-20; re-pin before implementation in Phase 2.

Source enumeration was done by `grep -r '^resource "' reference/aft/` and cross-checked against `reference/aft/modules/*/` and `docs/architecture/aft-analysis.md` §§1, 3, 4, 5, 7. Reconciliation with the aft-analysis "Cross-cutting observations" section: the DDB stream on `aft-request` is dropped entirely (see §4.1 — Git replaces the intake, `describe affected` replaces the stream); per-account dynamic pipelines are covered under §4 as deprecated; the three-role chain is rows 11 and 25; SSM-as-config-plane is row 10 (plus the per-account status row added in §4.1); customer-owned `aft-account-provisioning-customizations` SFN is the one place where row 14 (Step Functions module) might legitimately survive as a `workflow_call`-shaped extension point rather than be dropped wholesale — flagged for §7 review.

---

## 0. Hard boundary: Control Tower coexistence

This inventory assumes Control Tower owns the landing zone. Every module choice below respects the split; violations cause drift, duplicate recorders, or permission-set conflicts that manifest as a CT dashboard going red. Source: team-lead ADR (prior session).

### 0.1 Forbidden Cloudposse modules

Do not recommend, import, or wrap any of the following. They collide with resources CT already owns and any `terraform apply` attempting to re-create them will either fail or silently fight CT's drift-remediation.

| Forbidden module | Reason | Replacement |
|------------------|--------|-------------|
| `cloudposse/terraform-aws-organization` (any variant) | CT owns the AWS Organization | Read-only via `data "aws_organizations_organization"` |
| `cloudposse/terraform-aws-organizational-unit` | CT creates OUs through the Account Factory | Read-only via `data "aws_organizations_organizational_units"` |
| `cloudposse/terraform-aws-account` (cloudposse's account-provisioning module) | CT vends accounts via Service Catalog; a Terraform-native account create path bypasses CT guardrails | **Custom `account-provisioning` component** that wraps `aws_servicecatalog_provisioned_product` against the CT Account Factory product (replaces row 27 — see §2.5) |
| `cloudposse/terraform-aws-cloudtrail` at the *organization* scope | CT creates the org trail (`aws-controltower/CloudTrailLogs`) | Only recommended for *additional* per-account trails; never for the org trail |

### 0.2 Split of responsibilities

What **Control Tower owns** (do not model in Atmos, read only):

- AWS Organization, all OUs, the OU guardrails
- Account provisioning lifecycle (we trigger it, we do not own it)
- Organization-level CloudTrail → `aws-controltower/CloudTrailLogs` S3 bucket
- Baseline AWS Config rules delivered by CT (the `aws-controltower-*` rules set)
- Landing Zone baseline (CT StackSets, default CT KMS keys)

What **Atmos owns** (in this inventory):

- Additional SCPs beyond CT guardrails
- Per-account settings (IAM password policy, EBS default encryption)
- Budgets and cost alarms
- GuardDuty org-wide enablement (via delegated admin in the security account)
- Security Hub cross-region aggregation and standards subscriptions
- Config conformance packs and custom rules (NOT the recorder — see §5.5)
- Inspector2 org-wide scanning
- Identity Center permission sets and assignments
- VPC, IPAM, DNS, VPC Flow Logs
- GitHub OIDC providers and deployment roles
- Centralized logging buckets *additional to* the CT log archive (e.g., application-log lake, CloudTrail data-events, non-CT observability)
- The AFT replacement plane itself (everything in §2)

### 0.3 Mandatory CT-compat flags on security modules

See §5.5 for the full rationale. Headline rules any reviewer must enforce:

- **AWS Config**: Never create a configuration recorder or its IAM role in a CT-enrolled account; CT already did. Use only the `modules/cis-1-2-rules` and `modules/conformance-pack` submodules of `terraform-aws-config`, or vanilla `aws_config_config_rule` / `aws_config_conformance_pack`. The top-level `terraform-aws-config` module **always** creates a recorder (no escape hatch as of v1.6.1) and is therefore unusable against CT-enrolled accounts — listed as a gap in §5.5.
- **GuardDuty**: Design for three-phase deployment (delegated-admin registration → org-level settings → member invitations). CT does not manage GuardDuty, but the phasing matters.
- **Inspector2**: Safe to model fully in Atmos. CT does not touch it.
- **Security Hub**: Safe to manage cross-region aggregation and standards subscriptions; do not disable the CT-provisioned HOME_REGION hub.

---

## 1. Scope decisions before any mapping

Two things shrink the inventory substantially before we start mapping modules.

**We are not rebuilding AFT's CI/CD plane.** AFT ships with CodeCommit repositories, CodePipeline pipelines, CodeBuild projects, and CodeConnections (CodeStar) resources so that account customizations can be applied inside AWS from AWS-hosted git. The whole point of this project is to replace that with GitHub Actions. Everything in `reference/aft/modules/aft-code-repositories/` (CodeCommit, CodePipeline, CodeBuild, CodeConnections for github/gitlab/bitbucket/azuredevops/githubenterprise/gitlabselfmanaged) and the CodeBuild/CodePipeline pieces of `aft-customizations/` and `aft-lambda-layer/` have **no equivalent component** on our side — they are replaced by `gha-engineer`'s workflow topology. We list them in §4 for completeness but they are out of scope for module selection.

**AFT's private VPC, NAT gateways, and VPC endpoints exist only so that in-account CodeBuild can reach AWS APIs without traversing the public internet.** If we execute Terraform from GitHub Actions (public runners or ephemeral self-hosted runners in a shared VPC), we do not need the per-account VPC in the management account. This removes the `aws_vpc`, `aws_subnet`, `aws_nat_gateway`, `aws_eip`, `aws_internet_gateway`, `aws_route_table*`, `aws_security_group`, and ~17 `aws_vpc_endpoint` resources from `aft-account-request-framework/vpc.tf`. Flag this explicitly for `aws-architect` review — if the review lands on "runners must live in a VPC," we re-add a VPC component and the Cloudposse mapping below kicks in.

**AFT's Step Functions and Lambda pipeline (account creation orchestration) is replaced by GHA + account YAML + Atmos.** The account-request ingest (SQS + Lambda + Step Functions) and the per-account provisioning Step Function (`aft-account-provisioning-framework/states`) become a GitHub Actions workflow that reads an account-request YAML, calls `aws servicecatalog provision-product` (or the Control Tower `CreateManagedAccount` API), waits for completion, then runs `atmos terraform apply` against the new account. We therefore do **not** need a generic Step Functions module or the entire `aft_account_request_processor` Lambda chain. They appear in §4 as "deprecated by design."

**AFT's four DynamoDB tables (`aft-request`, `aft-request-audit`, `aft-request-metadata`, `aft-controltower-events`) are all dropped.** AFT uses DDB because it has no git-native inbox; we do. Git is the request ledger (stack YAML files are the requests, PRs are the audit trail, `git log` is point-in-time history). CloudTrail Lake in the audit account covers everything DDB couldn't — cross-service API calls, not just AFT's own writes. CT lifecycle events fan out via EventBridge → GHA `repository_dispatch` instead of landing in a table. The full replacement matrix is in §4.1; rows that used to map these tables are removed from §2.

What remains after those cuts is the durable state that any replacement still needs: Terraform state backends, KMS keys, SSM parameters that downstream account code reads, SNS notification topics, IAM roles for cross-account access, CloudWatch log groups, and an EventBridge rule that forwards CT lifecycle events to GHA. That is what §2 maps.

---

## 2. Mapping table: what stays, and what backs it

| # | AFT resource / module | Purpose | Recommended backing | Version | Notes |
|---|------------------------|---------|---------------------|---------|-------|
| 1 | `aft-backend` — S3 + DynamoDB state backend, cross-region replication, KMS, access logs bucket | Terraform remote state for AFT's management plane and every enrolled account | [`cloudposse/terraform-aws-tfstate-backend`](https://github.com/cloudposse/terraform-aws-tfstate-backend) | `v1.9.0` | **Topology: per-account primary + central bootstrap in aft-mgmt (task #9, see §2.6).** Two deployment shapes of the same module: (1) one instance per (account, region) creating `atmos-tfstate-<account-id>-<region>` with its own KMS CMK and `use_lockfile = true` (no DDB lock table); (2) one instance in aft-mgmt creating the `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>` bucket that holds only each account's `tfstate-backend` state. Cross-account read grant for `AtmosReadAllStateRole` is *not* native — added via `source_policy_documents` (S3) and a sibling `aws_kms_key_policy` (KMS). Full decision in `atmos-model.md` §9.3; GHA bootstrap in `gha-design.md` §5.8. Replication deferred — Phase 1 is single-region. |
| 2 | `aft-backend` — access logs bucket | Server access logging for the state bucket | [`cloudposse/terraform-aws-s3-log-storage`](https://github.com/cloudposse/terraform-aws-s3-log-storage) | `v2.0.0` | Dedicated log-storage bucket with lifecycle, encryption, BPA. Use as a sibling of the tfstate-backend instance; reference its `bucket_id` in the backend's `logging` block. |
| 3 | `aft-account-request-framework/kms.tf` — primary/secondary KMS keys for backend encryption | CMK for backend S3 + DynamoDB + SSM | [`cloudposse/terraform-aws-kms-key`](https://github.com/cloudposse/terraform-aws-kms-key) | `0.12.2` | One instance per region. The tfstate-backend module can also create its own KMS key — prefer to own the key externally so rotation and policy live with the rest of the KMS components. Module is on `0.x` but stable and widely used in Cloudposse refarch. |
| 4 | `aft-account-request-framework/ddb.tf` — `aft_request`, `aft_request_audit`, `aft_request_metadata` | Account-request ledger and audit trail | **Dropped — see §4.1** | n/a | All three tables are replaced by git-native surfaces. `aft-request` → stack YAML in Git (the PR *is* the request, merged main *is* the intake); `aft-request-audit` → CloudTrail Lake (in the audit account) + `git log`; `aft-request-metadata` → `atmos describe stacks` + `/aft/account/<name>/status` SSM parameter. No DynamoDB component needed. |
| 5 | `aft-account-request-framework` — `aft_controltower_events` DDB table | Append-only log of Control Tower Lifecycle events | **Dropped — see §4.1** | n/a | Replaced by an EventBridge rule on the CT management default bus that forwards `CreateManagedAccount` / `UpdateManagedAccount` events to GHA via `repository_dispatch` (event pattern in row 8). The event history then lives in CloudTrail Lake and in the GHA run log for the dispatched workflow — no DDB table required. |
| 6 | `aft-account-request-framework/sns.tf` — `aft_notifications`, `aft_failure_notifications` | Success/failure pubsub for account provisioning | [`cloudposse/terraform-aws-sns-topic`](https://github.com/cloudposse/terraform-aws-sns-topic) | `v1.2.0` | Two instances. The module handles KMS-encrypted topics, subscription policies, and DLQs. Wire these into the GHA workflow as the "something went wrong at apply time" channel. |
| 7 | `aft-account-request-framework/sqs.tf` — `aft_account_request`, `aft_account_request_dlq` | Account-request queue | **Vanilla `aws_sqs_queue`** _or_ [`terraform-aws-modules/terraform-aws-sqs`](https://registry.terraform.io/modules/terraform-aws-modules/sqs/aws) | n/a | **No Cloudposse standalone module exists.** Cloudposse's own `terraform-aws-components/modules/sqs-queue` wraps `terraform-aws-modules/sqs/aws` from the community registry — we can follow the same pattern or inline `aws_sqs_queue` + DLQ (~20 lines). Recommendation: vanilla, since the queue's API surface is small and we want to avoid pulling a non-Cloudposse module into the blessed set. Revisit if GHA-driven ingest removes the queue entirely, in which case drop this row. |
| 8 | `aft-account-request-framework/eventbridge.tf` + per-module `aws_cloudwatch_event_rule`/`aws_cloudwatch_event_target` | Event bus from CT management → AFT management; rules that fan control-tower lifecycle events into Lambda/Step Functions | [`cloudposse/terraform-aws-cloudwatch-events`](https://github.com/cloudposse/terraform-aws-cloudwatch-events) | `v0.10.0` | Covers `aws_cloudwatch_event_rule`, `aws_cloudwatch_event_target`, cross-account permissions. Does not cover `aws_cloudwatch_event_bus` or `aws_cloudwatch_event_permission` — compose the module with a vanilla `aws_cloudwatch_event_bus` for the `aft_from_ct_management` bus. Pattern already used by the upstream `cloudposse/terraform-aws-components/modules/eventbridge` wrapper (verified at `github-oidc-provider`-adjacent components). |
| 9 | Many `aws_cloudwatch_log_group` across all AFT Lambda/CodeBuild/Step Functions | Structured per-function log retention + KMS | [`cloudposse/terraform-aws-cloudwatch-logs`](https://github.com/cloudposse/terraform-aws-cloudwatch-logs) | `v0.6.9` | One module instance per logical log group. If we end up with tens of log groups, wrap the module in a small for_each helper inside each parent component rather than declaring the module N times in stack YAML. |
| 10 | `aft-ssm-parameters/ssm.tf` (~60 `aws_ssm_parameter` records that expose AFT internals to customer Terraform running in target accounts) | Cross-component contract: customer Terraform reads `/aft/account/*`, `/aft/resources/*`, `/aft/config/*` to discover state-bucket names, table names, SNS ARNs, repo refs, etc. | [`cloudposse/terraform-aws-ssm-parameter-store`](https://github.com/cloudposse/terraform-aws-ssm-parameter-store) | `0.13.0` | Accepts a map of parameters in one call — ideal for the "bulk publish" shape AFT uses. Consolidate all `/aft/*` SSM writes into one `ssm-parameters` component per account, fed via Atmos stack inheritance (see §6). Revisit the `/aft/config/*` subset: many of those parameters (VCS type, framework git ref, terraform version) are CI concerns now and belong in GHA variables, not SSM. |
| 11 | `aft-iam-roles/` — `AWSAFTAdmin`, `AWSAFTExecution`, `AWSAFTService` roles, plus HCP Terraform OIDC provider | Cross-account trust from the management account into every target account | [`cloudposse/terraform-aws-iam-role`](https://github.com/cloudposse/terraform-aws-iam-role) | `v0.23.0` | Module accepts trust-policy documents and inline/attached policies. The three AFT roles become three instances of this module per target account. The HCP Terraform OIDC provider is not covered (see row 24); replace with a GitHub OIDC provider component for GHA. |
| 12 | All `aws_iam_policy` / `aws_iam_role_policy` — dozens | Inline and managed policies attached to each Lambda/CodeBuild role | [`cloudposse/terraform-aws-iam-policy`](https://github.com/cloudposse/terraform-aws-iam-policy) | `v2.0.2` | v2 accepts policy documents as either `data.aws_iam_policy_document` JSON or as a structured `iam_policy` variable. Prefer the structured form in stack YAML so Atmos can merge policy statements across layers. |
| 13 | Every remaining `aws_lambda_function` that survives the GHA migration (candidates: `aft_controltower_event_logger`, `aft_delete_default_vpc`, `aft_enable_cloudtrail`, `aft_enroll_support`) | Per-account post-provision hooks | [`cloudposse/terraform-aws-lambda-function`](https://github.com/cloudposse/terraform-aws-lambda-function) | `v0.6.1` | Only keep Lambdas whose work genuinely must run in-account and async — the rest collapse into a GHA job. This module owns the function, role, log group, and optional VPC config. **Does not support Lambda layers as a managed resource** — see row 26. |
| 14 | `aws_sfn_state_machine` (`aft_account_provisioning_framework_sfn`, `aft_features`, `aft_invoke_customizations_sfn`, `aft_account_provisioning_customizations`) | Orchestration of per-account provisioning + customization fan-out | [`cloudposse/terraform-aws-step-functions`](https://github.com/cloudposse/terraform-aws-step-functions) | `0.2.0` | **Use sparingly.** The design direction is to replace Step Functions with GHA workflow jobs and `needs:` dependencies. If any step genuinely needs long-running AWS-native orchestration (e.g., waiting on CT `CreateManagedAccount` for an hour), keep it in SFN. Module is on `0.2.0` and has not moved in >3 years — stable but feature-thin; vanilla `aws_sfn_state_machine` is a close second if we hit a wall. |
| 15 | `aft-account-request-framework/backup.tf` — AWS Backup vault, plan, and selection for the DynamoDB request tables | Point-in-time backup of the request/audit ledger | **Dropped — DDB tables removed (§4.1)** | n/a | With rows 4 and 5 gone there is nothing to back up here. Git, CloudTrail Lake, and S3 Versioning on the tfstate bucket (row 1) already give point-in-time recovery for every surface that inherits the DDB tables' function. Keep `cloudposse/terraform-aws-backup` on the shelf for Phase 2 if another component ever needs AWS Backup (e.g., EBS snapshots, RDS), but do not ship a component on day one. |
| 16 | Access-logs bucket (`aft_access_logs`) and the `aft_logging_bucket` used by AFT's codepipeline-customizations bucket | Server access logs target | [`cloudposse/terraform-aws-s3-log-storage`](https://github.com/cloudposse/terraform-aws-s3-log-storage) | `v2.0.0` | Same module as row 2. Consolidate: one shared access-logs bucket per region, not one per source bucket. |
| 17 | Secondary/encrypted S3 buckets for customer-supplied assets (e.g., Lambda layer artifact store, bootstrap assets) | Generic object storage with BPA, SSE, versioning | [`cloudposse/terraform-aws-s3-bucket`](https://github.com/cloudposse/terraform-aws-s3-bucket) | `v4.12.0` | Preferred over writing `aws_s3_bucket` + the 7 related resources by hand. Handles replication, lifecycle, bucket policy, logging, CORS. |
| 18 | Control Tower notifications, CloudTrail (per-account) | CT audit trail — optional depending on whether we layer Security Hub / CT ourselves | [`cloudposse/terraform-aws-cloudtrail`](https://github.com/cloudposse/terraform-aws-cloudtrail) + [`cloudposse/terraform-aws-cloudtrail-s3-bucket`](https://github.com/cloudposse/terraform-aws-cloudtrail-s3-bucket) | `v0.24.0` / `1.2.0` | Only relevant if we take over what AFT's `aft_feature_cloudtrail_data_events` flag did. In a Control Tower landing zone this is usually already configured by CT itself — confirm with `aws-architect` before adding. |
| 19 | `aws_iam_openid_connect_provider "hcp_terraform"` | OIDC trust for Terraform Cloud/HCP to assume into the account | See §4 — drop | n/a | AFT offers this for customers who want to run their customizations on HCP. Our replacement runs on GHA, so swap in a **GitHub Actions OIDC provider**. No standalone Cloudposse module exists (confirmed 404 on `terraform-aws-github-oidc-provider`); `cloudposse/terraform-aws-components/modules/github-oidc-provider` is a thin component that uses vanilla resources. Copy that pattern (≈30 lines of `aws_iam_openid_connect_provider` + thumbprint data source) into a `github-oidc-provider` component. |
| 20 | CloudWatch Query Definitions (`account_id_query`, `customization_request_query`) | Saved CloudWatch Logs Insights queries that on-call uses | **Vanilla `aws_cloudwatch_query_definition`** | n/a | Tiny resource (3 fields), no Cloudposse module. Keep as vanilla inside the `aft-observability` component alongside log groups. |
| 21 | `random_string`, `random_uuid`, `time_sleep` | Eventual-consistency padding and resource-name suffixes | n/a | n/a | Keep inline where used. Not module territory. |
| 22 | `aws_default_security_group` with deny-all rules on AFT's VPC | Hardening default SG | [`cloudposse/terraform-aws-security-group`](https://github.com/cloudposse/terraform-aws-security-group) | `2.2.0` | Only if we re-add the VPC (see §1). Module supports `create_before_destroy`, revoke-defaults, etc. |
| 23 | `aws_vpc`, `aws_subnet`, `aws_nat_gateway`, `aws_internet_gateway`, `aws_route_table*`, `aws_eip` | Private VPC in the AFT management account | [`cloudposse/terraform-aws-vpc`](https://github.com/cloudposse/terraform-aws-vpc) + [`cloudposse/terraform-aws-dynamic-subnets`](https://github.com/cloudposse/terraform-aws-dynamic-subnets) | `v3.0.0` / `v3.1.1` | Only if we re-add the VPC. The v3 line of `terraform-aws-vpc` includes a `modules/vpc-endpoints` submodule that covers AFT's 17-endpoint gallery (codebuild, codecommit, codepipeline, ddb, events, git-codecommit, kms, lambda, logs, organizations, s3, servicecatalog, sns, sqs, ssm, states, sts) with an input map — no need for vanilla `aws_vpc_endpoint`. |
| 24 | GitHub OIDC provider + per-workflow role | Replace HCP OIDC (row 19) for GHA | **Vanilla** (pattern: `cloudposse/terraform-aws-components/modules/github-oidc-provider`) | n/a | See row 19 — write a small component, not a module. Justification: the OIDC provider has only two real inputs (issuer URL, thumbprint) and one resource. Wrapping it in a module adds cost without reuse. |
| 25 | Per-account `AWSAFTExecution`-style role provisioned into the *target* account | Cross-account admin role callable from the management account | [`cloudposse/terraform-aws-iam-role`](https://github.com/cloudposse/terraform-aws-iam-role) | `v0.23.0` | Same module as row 11, but instantiated under a provider alias pointing at the target account (see §5.2). This is the role GHA's OIDC flow assumes into each account. **Deployed into all five account classes, not only vended accounts** — CT-mgmt, AFT-mgmt, audit, log-archive, and every vended account each host one instance of `AtmosDeploymentRole`. The four CT-core placements predate Atmos, so they are stamped by `bootstrap.yaml` §5.8 step 5 via `_bootstrap-target.yaml` with `fallback_role=OrganizationAccountAccessRole`; vended-account placements are stamped by `provision-account.yaml` job 4 via the same reusable with `fallback_role=AWSControlTowerExecution`. Trust policy is identical across all five (see `gha-design.md §4.6`), differing only in an `sts:ExternalId` guardrail on the four CT-core variants. |
| 26 | `aws_lambda_layer_version "layer_version"` (Python deps for all AFT Lambdas) | Shared Python dep layer for in-account Lambdas | **Vanilla `aws_lambda_layer_version`** | n/a | No Cloudposse module exists (confirmed). AFT builds the layer via CodeBuild; our replacement builds it in GHA and uploads the zip to S3 in one step, then declares `aws_lambda_layer_version` pointing at that object. Drop `aft-lambda-layer` wholesale. |
| 27 | `aws_servicecatalog_*` interactions (AFT calls Service Catalog to provision the Control Tower Account Factory product) | Account creation trigger | **Custom `account-provisioning` component** wrapping vanilla `aws_servicecatalog_provisioned_product` | n/a | **Replaces `cloudposse/terraform-aws-account`** (forbidden — §0.1). CT's Account Factory is a Service Catalog product; `aws_servicecatalog_provisioned_product` is the managed resource that represents one account vended through it. Modelling it in Terraform (rather than shelling out from GHA) preserves drift detection, captures the account ID in state, and gives a clean `destroy`-equivalent path via Service Catalog's terminate action. Stack YAML supplies the provisioning parameters (account email, OU, SSO user) per account; one instance per account. |
| 28 | Control Tower Lifecycle — no direct Terraform resources, delivered via EventBridge | n/a | See row 8 | n/a | AFT consumes CT events; it does not create CT itself. Keep as-is. |
| 29 | AWS SSO permission sets (optional, not created by AFT by default) | If we want to stamp out SSO permission sets alongside accounts | [`cloudposse/terraform-aws-sso`](https://github.com/cloudposse/terraform-aws-sso) | `0.20.0` | Out of scope for the core replacement but a likely follow-on; name-drop for `aws-architect`. |

The version column is a release-tag snapshot, not a recommendation to float against `main` — pin the `source = "…"` / `ref=` in every component. Cloudposse's public registry module source form is `cloudposse/<name>/aws`; version is the `version = "…"` argument in the module block.

---

## 2.5 Additional Atmos-owned components beyond the core AFT replacement

These are not AFT resources but sit in the "what Atmos owns" bucket from §0.2. They need components in the same repo so that account vending and baseline hardening stay one workflow.

| # | Component | Purpose | Recommended backing | Version | Notes |
|---|-----------|---------|---------------------|---------|-------|
| 30 | `account-provisioning` | Trigger CT Account Factory to vend an account; capture account ID in state | **Vanilla** `aws_servicecatalog_provisioned_product` | n/a | Replaces `cloudposse/terraform-aws-account` (forbidden). See row 27. |
| 31 | `aws-scp` | Additional SCPs beyond CT guardrails, attached to specific OUs or accounts | [`cloudposse/terraform-aws-service-control-policies`](https://github.com/cloudposse/terraform-aws-service-control-policies) | `v0.15.2` | Active module (latest Dec 2025). Uses Cloudposse's `config/yaml` helper to compose statement fragments — the same pattern the `terraform-aws-components/modules/account` wrapper uses. Never reference CT's own guardrail SCPs; attach only to targets CT does not already constrain. |
| 32 | `aws-account-settings` | Per-account IAM password policy, EBS default encryption, default region settings | **Vanilla** (`aws_iam_account_password_policy`, `aws_ebs_encryption_by_default`, `aws_ebs_default_kms_key`) | n/a | No standalone Cloudposse module (`terraform-aws-account-settings` does not exist; the `terraform-aws-components/modules/account-settings` component uses vanilla resources). Keep each field in stack YAML so per-account overrides are explicit. |
| 33 | `aws-budgets` | Per-account cost budgets with SNS alerts | [`cloudposse/terraform-aws-budgets`](https://github.com/cloudposse/terraform-aws-budgets) | `v0.8.0` | Thin module, cost-effective to adopt; accepts a list of budgets. Subscribe to the `aft_notifications` SNS topic (row 6) for consistent routing. |
| 34 | `guardduty-root` | Register the security account as GuardDuty delegated admin from the org root | [`cloudposse/terraform-aws-guardduty`](https://github.com/cloudposse/terraform-aws-guardduty) | `v1.0.0` | **Phase 1 of 3 (§5.5)**. Runs in the management account. Sets `aws_guardduty_organization_admin_account`. |
| 35 | `guardduty-delegated-admin` | Configure org-wide GuardDuty settings and auto-enable from the delegated-admin account | [`cloudposse/terraform-aws-guardduty`](https://github.com/cloudposse/terraform-aws-guardduty) | `v1.0.0` | **Phase 2 of 3**. Runs in the security/audit account. Owns `aws_guardduty_organization_configuration` and the detector-level features (malware scan, runtime monitoring, EKS audit logs). |
| 36 | `guardduty-member-settings` | Per-account detector-level features + membership | [`cloudposse/terraform-aws-guardduty`](https://github.com/cloudposse/terraform-aws-guardduty) | `v1.0.0` | **Phase 3 of 3**. Runs in each member account. |
| 37 | `security-hub` | Cross-region finding aggregator + standards subscriptions | [`cloudposse/terraform-aws-security-hub`](https://github.com/cloudposse/terraform-aws-security-hub) | `0.12.2` | Active but pre-1.0. One instance in the security account for the aggregator; per-account instances subscribe to standards. Do not call `aws_securityhub_account` in the CT HOME_REGION — CT already enabled it; the module handles this by keying on `enabled`. |
| 38 | `aws-config-rules` | Custom Config rules beyond CT's baseline | `cloudposse/terraform-aws-config//modules/cis-1-2-rules` submodule *or* vanilla `aws_config_config_rule` | `v1.6.1` | **Never use the top-level `terraform-aws-config` module** — it always creates a recorder (§5.5). Submodules `cis-1-2-rules` and `conformance-pack` are CT-safe. |
| 39 | `aws-config-conformance-pack` | Conformance packs (CIS, PCI-DSS, FedRAMP) | `cloudposse/terraform-aws-config//modules/conformance-pack` submodule | `v1.6.1` | Same submodule caveat as row 38. |
| 40 | `inspector2` | Org-wide Inspector v2 scanning | **Vanilla** (`aws_inspector2_delegated_admin_account`, `aws_inspector2_organization_configuration`, `aws_inspector2_enabler`) | n/a | No Cloudposse standalone module. The `terraform-aws-components/modules/aws-inspector2` component uses vanilla resources and is the pattern to copy. Safe to model fully in Atmos — CT does not manage Inspector2. |
| 41 | `identity-center-permission-sets` | SSO permission sets (admin, developer, read-only, etc.) | [`cloudposse/terraform-aws-sso`](https://github.com/cloudposse/terraform-aws-sso) | `1.2.0` | Active module. Accepts maps of permission sets + assignments; designed for org-wide deployment from the management account. |
| 42 | `identity-center-assignments` | Bind permission sets to accounts + groups | [`cloudposse/terraform-aws-sso`](https://github.com/cloudposse/terraform-aws-sso) | `1.2.0` | Same module as row 41; separated so that new-account vending does not force a re-apply of the permission-set definitions. |
| 43 | `ipam` | Centralised IP address management for the org | **Vanilla** (`aws_vpc_ipam`, `aws_vpc_ipam_pool`, `aws_vpc_ipam_pool_cidr`, `aws_vpc_ipam_scope`) | n/a | No Cloudposse module (`terraform-aws-ipam` does not exist, confirmed 404). Small resource surface; vanilla is the right call. Share pool IDs via Atmos remote-state to the VPC component (row 23). |
| 44 | `dns-primary` + `dns-delegated` | Root hosted zone + per-account delegated subzones | `cloudposse/terraform-aws-components/modules/dns-primary` and `.../dns-delegated` (pattern) | n/a | Not module-backed; these are pure vanilla `aws_route53_zone` + `aws_route53_record` components in the upstream refarch. Copy the pattern. |
| 45 | `vpc-flow-logs-bucket` | Shared S3 bucket for Flow Logs across accounts | [`cloudposse/terraform-aws-vpc-flow-logs-s3-bucket`](https://github.com/cloudposse/terraform-aws-vpc-flow-logs-s3-bucket) | `v1.3.1` | Active (Aug 2025). One per region in the security/audit account. |
| 46 | `centralized-logging-bucket` | Additional (non-CT) log lake — application logs, CloudTrail data events, etc. | [`cloudposse/terraform-aws-s3-bucket`](https://github.com/cloudposse/terraform-aws-s3-bucket) | `v4.12.0` | Never target the CT `aws-controltower/CloudTrailLogs` bucket; this is an **additional** bucket. |
| 47 | `cloudtrail-additional` | Extra per-account CloudTrail trail (e.g., data events) | [`cloudposse/terraform-aws-cloudtrail`](https://github.com/cloudposse/terraform-aws-cloudtrail) + [`cloudposse/terraform-aws-cloudtrail-s3-bucket`](https://github.com/cloudposse/terraform-aws-cloudtrail-s3-bucket) | `0.24.0` / `1.2.0` | Only for supplementary trails — never override the org trail CT manages. |
| 48 | `tfstate-backend-central` | aft-mgmt-only bootstrap bucket holding each account's `tfstate-backend` state (resolves the chicken-and-egg from row 1) | [`cloudposse/terraform-aws-tfstate-backend`](https://github.com/cloudposse/terraform-aws-tfstate-backend) | `v1.9.0` | Same backing module as row 1, different component because the shape is aft-mgmt-only and its inputs differ: bucket `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>`, key-prefix `bootstrap/<account-id>/`, CMK alias `alias/atmos-tfstate-bootstrap`. Single instance in the aft-mgmt stack. Short-lived in the sense that it only stores bootstrap state, not workload state. Bootstrapped by the `bootstrap.yaml` GHA workflow (`gha-design.md` §5.8) using local state, then `migrate-state`d into itself once. See `atmos-model.md` §9.3.1/§9.3.3 step 1 and §2.6 of this doc. |

---

## 2.6 State backend topology — decision tie-in for row 1

Row 1 (`cloudposse/terraform-aws-tfstate-backend` v1.9.0) is the module we deploy to satisfy Blocker 3 from `review.md` §4.3 (task #9). The full decision lives in `atmos-model.md` §9.3 and `gha-design.md` §5.8/§12 — this section documents why the module choice is consistent with it, and what additional configuration the module needs on top of its defaults.

### 2.6.1 Topology summary

- **Primary state backend: per-account, not central.** Every enrolled account (including mgmt, audit, security, and every workload account) runs one instance of the `tfstate-backend` component that creates an S3 bucket and KMS CMK *in that account*. Bucket naming: `atmos-tfstate-<account_id>-<region>`. This keeps blast radius per-account, aligns S3 bucket policies with account boundaries, and means a compromised account cannot rewrite another account's state.
- **Central bootstrap bucket in aft-mgmt.** One additional instance of the same module lives in the aft-mgmt account as `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>` and holds the state *only* for each account's own `tfstate-backend` component (key `bootstrap/<account-id>/tfstate-backend/terraform.tfstate`). This resolves the chicken-and-egg: the component that creates an account's state bucket cannot store its state in that same bucket.
- **Per-account CMK, not shared.** Each account's `tfstate-backend` instance creates its own KMS CMK (alias `alias/atmos-tfstate`). Cross-account reads (drift, `atmos describe affected` summaries) are granted via KMS key policy and S3 bucket policy to a single `AtmosReadAllStateRole` that lives in aft-mgmt — no shared CMK, no cross-account key-ownership ambiguity.
- **No DynamoDB lock table.** S3 native locking (`use_lockfile: true`, requires Terraform ≥ 1.10) replaces the lock table — one of the reasons AFT's four DDB tables are all dropped (§4.1).

### 2.6.2 Does `terraform-aws-tfstate-backend` v1.9.0 support this topology?

Yes, with the configuration below. Relevant module behaviour verified against the v1.9.0 source:

| Requirement | Module support | How it's satisfied |
|-------------|----------------|--------------------|
| One S3 bucket + one KMS CMK per instance | Native — module's default shape | Instantiate once per (account, region) stack. |
| Bucket name under our control | `bucket_prefix` / `namespace`-driven naming | Use `context.tf` inputs (§5.1) to render `atmos-tfstate-<account_id>-<region>`. |
| KMS CMK created and owned by the module | `create_kms_key = true` (default) | Leave default. Alias via `kms_alias_name` input. |
| S3 native locking | `use_lockfile` supported from `v1.8.0+` (verified in v1.9.0 variables.tf) | Set `use_lockfile = true`. Do not create a DynamoDB lock table (`dynamodb_enabled = false`). |
| `DenyInsecureTransport` bucket policy | Not added by default | Inject via the module's `source_policy_documents` input (merges extra statements into the generated bucket policy). |
| Cross-account `AtmosReadAllStateRole` grant on S3 and KMS | **Not native** | See §2.6.3 — requires one extra policy fragment on S3 and a sibling `aws_kms_key_policy` or inline KMS policy extension. |
| Second instance in aft-mgmt for bootstrap bucket | Native — just a second module call with different vars | Renders as component `tfstate-backend-central` (row 48) in the aft-mgmt stack only. |

Version pin stays at `v1.9.0` — no need to bump.

### 2.6.3 What the module does not give us for free

The cross-account read grant (`AtmosReadAllStateRole`) is the one input the module does not surface natively. Two implementation options, both cheap:

1. **Policy-document composition via `source_policy_documents`.** The module accepts a list of `source_policy_documents` (strings, typically `data.aws_iam_policy_document` JSONs) that get merged into the generated bucket policy. Add a `data "aws_iam_policy_document"` fragment in the component code that grants `s3:GetObject` / `s3:ListBucket` to `arn:aws:iam::<aft-mgmt-id>:role/AtmosReadAllStateRole`. This is the preferred path — keeps the policy co-located with the bucket.
2. **Sibling `aws_kms_key_policy` on the module-created CMK.** The module creates the CMK but does not expose a hook to extend its key policy. Re-apply a full key policy via `aws_kms_key_policy` in the same component code, using the module's `kms_key_id` output as the target. Template the key policy per `atmos-model.md` §9.3.2 (account-root `kms:*`, local `AtmosDeploymentRole` full crypto, `AtmosCentralDeploymentRole` full crypto, `AtmosReadAllStateRole` decrypt-only with `kms:ViaService` condition).

Both patterns should ship inside the `tfstate-backend` component wrapper (`components/terraform/tfstate-backend/main.tf`) rather than as ad-hoc overrides in stack YAML — the stack YAML only supplies the list of principals.

### 2.6.4 Bootstrap order (cross-ref)

The full bootstrap order is in `atmos-model.md` §9.3.3 and the matching GHA workflow is in `gha-design.md` §5.8. Summary: one operator-run `migrate-state` for the aft-mgmt `tfstate-backend` instance after its state is moved from the bootstrap bucket into its own bucket (Phase 2 housekeeping). Every other account's `tfstate-backend` state is born in the central bootstrap bucket and **stays there permanently** — no migration needed for 99% of accounts, because a given account's bootstrap state is small, read-rarely, and does not benefit from being in the same bucket as the account's workload state.

### 2.6.5 Open items

- **Per-account CMK cost.** Each CMK is $1/month. At 200 accounts × 1 region = $200/month; acceptable. If we go multi-region primary (not Phase 1), revisit.
- **DR (cross-region replication).** Deferred — Phase 1 is single-region. If DR is required later, the module supports replication via a `replication_role_arn` input + a sibling replication configuration; revisit at the same time we revisit row 1's version pin.
- **`aft-mgmt`'s own `tfstate-backend` state.** Lives in the bootstrap bucket in Phase 1 (same as every other account). Moving it into the aft-mgmt primary bucket is Phase 2 housekeeping — the only `migrate-state` we ever run. Tracked in `atmos-model.md` §9.3.5.

---

## 3. Recommended Atmos component layout

One folder per component under `components/terraform/<name>/`. Each folder contains a Terraform root module that wraps exactly one backing module (or, where a component spans multiple resources, a small composition). This matches the Cloudposse `terraform-aws-components` pattern from §2 lookups.

```
components/terraform/
├── tfstate-backend/                  # Row 1 — per-account primary state bucket + CMK (instance per account+region)
├── tfstate-backend-central/          # Row 48 — aft-mgmt-only bootstrap bucket holding each account's tfstate-backend state
├── account-request-kms/              # Rows 3 — CMK per region (two instances: primary, secondary)
├── account-request-notifications/    # Row 6 — SNS (success + failure)
├── account-request-queue/            # Row 7 — SQS queue + DLQ (vanilla)
├── controltower-event-bridge/        # Row 8 — event bus + rules + repository_dispatch forwarder (replaces aft_controltower_events DDB, §4.1)
├── cloudwatch-log-groups/            # Row 9 — one for_each map of log groups + retention
├── aft-ssm-parameters/               # Row 10 — bulk /aft/* parameter writer
├── iam-roles-management/             # Row 11 — AFT admin/execution/service roles (mgmt account)
├── iam-roles-target-account/         # Row 25 — execution role stamped into every target account (all five classes: CT-mgmt, AFT-mgmt, audit, log-archive, vended — see gha-design.md §4.6)
├── github-oidc-provider/             # Row 24 — OIDC provider + GHA role (target account)
├── aft-lifecycle-lambdas/            # Row 13 — only the Lambdas we keep (cloudtrail enable, etc.)
├── aft-access-logs-bucket/           # Row 16 — shared access-logs bucket per region
├── aft-observability/                # Row 20 — saved CloudWatch Insights queries
│
│ # CT-coexistence & org baseline components (§2.5)
├── account-provisioning/             # Row 30 — aws_servicecatalog_provisioned_product (CT Account Factory)
├── aws-scp/                          # Row 31 — additional SCPs (never CT guardrails)
├── aws-account-settings/             # Row 32 — IAM password policy, EBS encryption (vanilla)
├── aws-budgets/                      # Row 33
├── guardduty-root/                   # Row 34 — delegated-admin registration (mgmt account)
├── guardduty-delegated-admin/        # Row 35 — org-level config (security account)
├── guardduty-member-settings/        # Row 36 — per-account detector features
├── security-hub/                     # Row 37
├── aws-config-rules/                 # Row 38 — submodule-backed, never top-level
├── aws-config-conformance-pack/      # Row 39
├── inspector2/                       # Row 40 — vanilla
├── identity-center-permission-sets/  # Row 41
├── identity-center-assignments/      # Row 42
├── ipam/                             # Row 43 — vanilla
├── dns-primary/                      # Row 44 — vanilla
├── dns-delegated/                    # Row 44 — vanilla
├── vpc-flow-logs-bucket/             # Row 45
├── centralized-logging-bucket/       # Row 46
└── cloudtrail-additional/            # Row 47 — opt-in only, never the org trail
```

Each folder is a **root module** that Atmos invokes. Inputs come from stack YAML via Atmos's `vars:` block. Outputs are consumed by downstream components via Atmos `remote-state` lookups (not by wiring outputs through stack YAML manually — see §5.3).

Deliberately not present: anything under `reference/aft/modules/aft-code-repositories/`, anything under `aft-customizations/` that is CodePipeline/CodeBuild-adjacent, `aft-account-request-framework/vpc.tf` (unless `aws-architect` says otherwise), `aft-lambda-layer/` in module form.

---

## 4. Deprecated by design — do not build a component

These AFT resources have no replacement on our side. They are listed so downstream reviewers can quickly verify nothing fell through.

| AFT module | Resources | Replaced by |
|------------|-----------|-------------|
| `aft-code-repositories` (entire module) | CodeCommit repos (×4), CodePipeline (×6), CodeBuild (×1), CodeConnections (×6) hosts & connections | GitHub Actions + the GitHub org itself hosts the four conceptual repos (`aft-account-request`, `aft-account-provisioning-customizations`, `aft-global-customizations`, `aft-account-customizations`). |
| `aft-lambda-layer` | CodeBuild project + IAM + VPC access to build the Python layer | GHA build step uploads layer zip to S3; `aws_lambda_layer_version` points at it (row 26). |
| `aft-account-request-framework` — `aft_account_request_processor` Lambda + its SQS event source mapping | The service that consumes the SQS queue and kicks Step Functions | GHA `on: push` to the account-requests repo parses the YAML and calls `aws servicecatalog provision-product` directly (row 27). |
| `aft-account-provisioning-framework/states` + `aft-customizations/states` | Two Step Functions state machines | GHA workflow with sequential jobs + `needs:`. Kept as a Step Function only if `aws-architect` finds a long-running waiter that genuinely needs an AWS-native orchestrator. |
| `aft_account_customizations_terraform` / `aft_global_customizations_terraform` CodeBuild projects | In-account terraform apply runner | `atmos terraform apply` from GHA, authenticated via OIDC into the target account's `iam-roles-target-account` role (row 25). |
| HCP Terraform OIDC provider | Optional trust for Terraform Cloud | Replaced by GitHub OIDC provider (rows 19/24). |
| The entire AFT management-account VPC + 17 VPC endpoints | Network isolation for in-account CodeBuild | No longer relevant once CodeBuild is gone. Revisit only if runners move into AWS. |

Everything in this table must be explicitly ACK'd by `aws-architect` in the design review. If any of these flip back to "we need it," row 22 / 23 / 14 in §2 are the correct backings.

### 4.1 DynamoDB tables — replacement matrix

AFT's four DDB tables (§2 rows 4 and 5, now dropped) each carried a distinct function. The replacement is not one thing — it's four different surfaces, each already present in a GHA + Atmos world.

| AFT table | What it was for | Replacement | Where it lives | Read/write paths |
|-----------|-----------------|-------------|----------------|------------------|
| `aft-request` | Intake queue: account-request JSON blobs written by the request-repo Lambda, consumed by the provisioning Step Function | **Git — stack YAML is the request** | `stacks/orgs/<org>/<tenant>/<stage>/<region>.yaml` in this repo; each `account-provisioning` component instance *is* one pending request | Write: PR opens → approves → merges to `main`. Read: `atmos describe affected` on the merge commit yields the new component instances to apply. |
| `aft-request-audit` | Append-only history of every request, status transition, and error | **CloudTrail Lake + `git log`** | CloudTrail Lake event data store in the audit account (covers every AWS API call AFT used to log); `git log` on the request repo (covers every request's full text + approval metadata) | Query: CloudTrail Lake SQL for "who called `servicecatalog:ProvisionProduct` for account X"; `git log --follow <account>.yaml` for the YAML history. Retention: CloudTrail Lake 7 years default; git is permanent. |
| `aft-request-metadata` | Current status and derived attributes per account (account_id, email, OU, state = `PROVISIONING`/`PROVISIONED`/`FAILED`) | **`atmos describe stacks` + `/aft/account/<name>/status` SSM parameter** | `atmos describe stacks --component account-provisioning` resolves every account's declared state from YAML; the single `/aft/account/<name>/status` SSM parameter per account carries the *runtime* state (written by the provisioning workflow) | Write: the provisioning GHA workflow writes `/aft/account/<name>/status` on job transitions. Read: ops dashboards query SSM; Terraform reads via `data "aws_ssm_parameter"`. |
| `aft-controltower-events` | Append-only log of CT lifecycle events (`CreateManagedAccount`, `UpdateManagedAccount`) captured from the mgmt-account event bus | **EventBridge → GHA `repository_dispatch`** | Rule on the CT management account's `default` bus (component `controltower-event-bridge`, row 8) matches `aws.controltower` events and invokes a connection-backed API-destination that POSTs to `https://api.github.com/repos/<org>/<repo>/dispatches` with an `event_type` of `ct-lifecycle`. The GHA run log is the event archive. | Write: CT fires the event, rule forwards, GHA dispatches workflow. Read: GHA run history + CloudTrail Lake (the `PutEvents` is logged). |

Implementation notes for §4.1:

- The SSM parameter (`/aft/account/<name>/status`) has the opposite write-access pattern from the DDB table it replaces: AFT wrote to DDB from the mgmt account; we write the SSM parameter *inside the target account*, under the `iam-roles-target-account` role, so each account owns its own state row. Cross-account reads go through a small IAM policy in the ops-reader role.
- EventBridge → `repository_dispatch` requires an API destination + connection (GitHub PAT or GitHub App installation token stored in Secrets Manager). This lives in the `controltower-event-bridge` component (row 8); the rule target is a connection-backed API destination, not a Lambda.
- Retention decisions: CloudTrail Lake event data stores default to 7 years but can be set to 10 at create-time; set this at Phase 2. Git is permanent (subject to repo retention). GHA run logs retain 90 days by default — if we need longer, archive workflow `repository_dispatch` payloads to S3 via the first job in every dispatched workflow.
- CloudTrail Lake is assumed to exist in the audit account (created either by CT add-on or by a `cloudtrail-lake` component we stand up in the audit stack). Added to §7 as an open question so `aws-architect` confirms scope.

---

## 5. Cloudposse conventions to bake in now

These are the traps a downstream implementer hits on day one. Put them in the team's internal README before Phase 2 starts.

### 5.1 `null-label` / `context.tf`

Every Cloudposse module accepts the [`null-label`](https://github.com/cloudposse/terraform-null-label) input contract. Each component must drop a copy of `context.tf` at the component root (Cloudposse distributes a canonical file; copy it verbatim). The contract provides these inputs: `namespace`, `tenant`, `environment`, `stage`, `name`, `attributes`, `tags`, `delimiter`, `label_order`, plus the pre-assembled `context` object. Stacks feed `namespace`/`tenant`/`environment`/`stage` through the `_defaults.yaml` chain described in `docs/architecture/atmos-model.md`; components do not set these themselves.

The module's generated `id` (`<namespace>-<tenant>-<environment>-<stage>-<name>`) becomes the default resource name, so renaming a component's `name` input rotates every resource and its state address — treat it as a breaking change. `metadata.name:` on the component instance freezes the backend workspace key prefix so state survives the rename; use it.

Cross-reference: `terraform-null-label` is pinned at `0.25.0` and has not moved since 2021 — that is the stable line, not abandonment. Do not bump to a pre-release.

### 5.2 Provider aliases for multi-account

None of the Cloudposse `terraform-aws-*` modules take a provider as an input variable — they consume the default `aws` provider. For a factory that stamps one component into dozens of target accounts from the management account, you must:

1. In the component's `providers.tf`, declare the expected providers (`aws` = management account, `aws.target` = target account).
2. Use Atmos's `providers:` block in the stack YAML to render the right `assume_role` config per instance — Atmos composes the provider block per `(component, stack)` run.
3. Pass the module that must execute in the target account a `providers = { aws = aws.target }` block at the `module ""` call site.

This pattern is the one documented under `auth:` / `providers:` in `reference/atmos/examples/quick-start-advanced/atmos.yaml` and is why `iam-roles-target-account` (row 25) is a separate component from `iam-roles-management` (row 11) even though both use `terraform-aws-iam-role`.

### 5.3 The `enabled` flag and output shape

Every Cloudposse module honours `enabled = false` as "create no resources, still produce the output object" — most outputs become `null`. Never wrap a module block in `count = var.create ? 1 : 0`; set `enabled` and let the module handle it. Downstream components that read via `remote-state` should tolerate null outputs (use `try(..., default)`), because an upstream component may legitimately be `enabled = false` in a given stack.

Outputs are typically shaped as `{ <logical_name> = { id = ..., arn = ..., ...} }` or flat `<resource>_arn` / `<resource>_id` pairs. Expose these from each component `outputs.tf` unmodified so Atmos's `remote_state_backend` lookups can find predictable keys.

### 5.4 Modules to watch for deprecation risk

| Module | Concern |
|--------|---------|
| `terraform-aws-step-functions` v0.2.0 | Last release March 2023. Still works against current provider, but the feature gap (no Express workflows, no X-Ray config) means a future need may force vanilla. |
| `terraform-aws-iam-assumed-roles` v0.6.0 (2019) | Effectively abandoned. Do **not** use; `terraform-aws-iam-role` is the live replacement. |
| `terraform-aws-ssm-parameter-store` v0.13.0 | Pre-1.0, but stable and the canonical bulk-param pattern across Cloudposse refarch. |
| `terraform-aws-codebuild` v2.0.2 | We are not using it, but note: it's alive at 2.x if the CodeBuild pieces ever come back. |

No modules in the shortlist are archived or deprecated by the maintainer as of this writing. Re-verify at pin-time.

### 5.5 CT-compat flags — the deep dive

Per §0.3, three security modules need care when deployed into a Control Tower landing zone. Details follow.

**AWS Config (`cloudposse/terraform-aws-config` v1.6.1).** CT-enrolled accounts already have a configuration recorder (`default`) and a delivery channel provisioned by the CT StackSet. The cloudposse top-level module always runs `aws_config_configuration_recorder.recorder` with `count = module.this.enabled ? 1 : 0` — there is **no `create_recorder` flag**. Setting `enabled = false` disables the entire module including the parts we actually want (rules, aggregator). Consequence: the top-level module is unusable in CT-enrolled accounts. Two safe paths:

1. Use the `modules/cis-1-2-rules` and `modules/conformance-pack` submodules directly. These create only rules/packs, no recorder.
2. Fall back to vanilla `aws_config_config_rule` / `aws_config_conformance_pack` for anything the submodules do not cover.

The `create_iam_role = false` pattern the ADR asked for **is** present in the top-level module (`local.create_iam_role`), but since we cannot suppress the recorder, it is moot here. This is a genuine gap worth raising upstream.

**GuardDuty (`cloudposse/terraform-aws-guardduty` v1.0.0).** The module is CT-safe (CT does not manage GuardDuty), but org-wide GuardDuty requires three applies in three identities because of AWS API coupling:

1. **Root / management account** (component `guardduty-root`): `aws_guardduty_organization_admin_account` registers the security/audit account as delegated admin. The module exposes this via its root-scope flow.
2. **Delegated-admin account** (component `guardduty-delegated-admin`): `aws_guardduty_detector` + `aws_guardduty_organization_configuration` with `auto_enable_organization_members = "ALL"`, plus the detector features (malware scan, runtime monitoring, EKS audit logs, Lambda network logs, S3 protection).
3. **Member accounts** (component `guardduty-member-settings`): per-account detector-level feature overrides if any differ from the org default.

The three phases cannot collapse into one component because each runs under a different provider alias (different assumed role). Stack inheritance should carry the common settings (feature flags, finding frequency) and override the identity per phase via `providers:`.

**Security Hub (`cloudposse/terraform-aws-security-hub` v0.12.2).** CT enables Security Hub in the HOME_REGION during landing-zone setup. Our component must not re-create `aws_securityhub_account` there, but we do need to: (a) subscribe to standards (CIS, PCI-DSS, AWS Foundational), (b) configure cross-region finding aggregation from the security account, (c) mark the security account as delegated admin via `aws_securityhub_organization_admin_account` from the management account. The module supports (a) and (b); (c) needs one extra vanilla resource. Check `enabled` behaviour before assuming the module skips account enablement — an apply in HOME_REGION may still try to re-enable. If it does, fall back to vanilla for the account-level resource and keep the module for standards/aggregation only.

**Inspector2.** No Cloudposse module. Use vanilla `aws_inspector2_delegated_admin_account` (management account), `aws_inspector2_organization_configuration` + `aws_inspector2_enabler` (delegated admin), `aws_inspector2_member_association` (per-member). Mirrors the GuardDuty three-phase split.

---

## 6. How Atmos stack inheritance should feed these modules

The `docs/architecture/atmos-model.md` §3 chain — org `_defaults` → tenant `_defaults` → stage `_defaults` → region mixin → leaf — produces a resolved `vars` block. For our components the split is:

- **Org-level `_defaults.yaml`** sets `namespace`, `tags` (compliance/cost allocation), and any organization-wide constants (`aft_management_account_id`, `ct_home_region`).
- **Tenant-level `_defaults.yaml`** sets `tenant`. Our tenants are roughly "aft-core" (the management-plane components) and per-OU tenants for target-account customizations.
- **Stage-level `_defaults.yaml`** sets `stage` — `mgmt` for the AFT management account, `prod`/`dev`/`security`/`audit` for downstream.
- **Region mixin** (`mixins/region/us-east-1.yaml` etc.) sets `region`.
- **Leaf** (`stacks/orgs/<org>/<tenant>/<stage>/<region>.yaml`) declares which components exist in that stack and sets component-specific `vars`.

Component-specific variables land via `components.terraform.<name>.vars` at any layer. For example, `aft-ssm-parameters` accepts a `parameters` map; the map is assembled by merging `_defaults.yaml` contributions across the hierarchy with `settings.list_merge_strategy: merge` so each layer can add its own `/aft/*` keys without stomping the parent.

Abstract components (`metadata.type: abstract`) are useful here for `iam-roles-target-account`: one abstract component defines the three AFT roles' trust and policy scaffolding; each target-account stack inherits from it via `metadata.inherits:` and supplies only the target account ID and any account-specific trust refinements.

One explicit rule: **never pass a remote-state output through YAML**. If component B needs component A's output, B declares an Atmos `remote-state` datasource in its component code; B's stack YAML supplies only the `(component, stack)` pointer to A. This keeps stack YAML free of literal ARNs that rot.

---

## 7. Gaps and open questions for the design review

Flag these in the Phase 1 review with `aws-architect`:

1. **Do we keep SQS for account-request ingest, or collapse it into GHA `workflow_dispatch`?** If we collapse, drop row 7 entirely.
2. **Do we keep the in-account Lambdas (`delete_default_vpc`, `enable_cloudtrail`, `enroll_support`) or move that work to GHA steps?** The Lambdas are easier to run async per-account; GHA steps are easier to debug. Default recommendation: keep them as Lambdas (row 13) only if they must run without a pre-existing assumable role — otherwise fold them into GHA jobs that assume the execution role.
3. **Do we need AFT's private VPC?** Depends on the GHA runner story. If self-hosted runners live in AWS, a shared VPC may be justified; if we use GitHub-hosted runners with OIDC, there is no VPC. Rows 22, 23 hinge on this.
4. **State backend scope.** AFT maintains one state bucket per "flavour" (account-request, customizations). Do we want one backend bucket per component category, or a single shared backend with per-component `workspace_key_prefix`? Cloudposse's convention is a single backend; refer `aws-architect` to the `tfstate-backend` component.
5. **Service Catalog product for account creation.** Confirm we are happy to call `aws servicecatalog provision-product` from GHA rather than modelling the provisioned-product as a Terraform resource. The trade is discoverability (Terraform-managed) vs. avoiding a noisy drift signal (the product is essentially write-once, read-never).
6. **AFT `aft-feature-options` KMS key replication in primary+secondary regions.** Do we still want dual-region KMS if the backend is not geo-replicated? Probably no; simplify to one region unless `aws-architect` requires DR.
7. **CloudTrail Lake event data store in the audit account.** §4.1 assumes this exists (replaces `aft-request-audit`). Confirm scope: is it provisioned as part of the CT add-ons, or do we need a `cloudtrail-lake` component in the audit stack? Retention default (7y vs 10y) and SQL-query access pattern for ops need to be settled before Phase 2.
8. **EventBridge → GHA `repository_dispatch` connection secret.** §4.1 assumes a GitHub App installation token in Secrets Manager, rotated by the app's short-lived token flow. Confirm the auth mechanism with `gha-engineer` — a PAT works but is a long-lived credential in the mgmt account.

---

## 8. Change log

- 2026-04-20 — Initial inventory. Module versions pinned to latest stable release as of this date. No implementation started.
- 2026-04-20 — Added §0 (Control Tower coexistence hard boundary), §2.5 (Atmos-owned security & org-baseline components, rows 30–47), §5.5 (CT-compat flag deep-dive for Config/GuardDuty/Security Hub/Inspector2). Updated row 27 to name the custom `account-provisioning` component as the replacement for the forbidden `cloudposse/terraform-aws-account`. Expanded §3 component layout with the new components.
- 2026-04-20 — Reconciled with `mapping.md §4.1`: dropped all four AFT DynamoDB tables (rows 4 and 5) and the AWS Backup component that covered them (row 15). Added §4.1 replacement matrix documenting the four surfaces that take over (`aft-request` → Git; `aft-request-audit` → CloudTrail Lake + `git log`; `aft-request-metadata` → `atmos describe stacks` + `/aft/account/<n>/status` SSM; `aft-controltower-events` → EventBridge → GHA `repository_dispatch`). Removed `account-request-ledger/` and `aft-backup/` from §3 component layout. Updated §1 prose and §7 open questions to match.
- 2026-04-20 — Task #9: Added §2.6 "State backend topology — decision tie-in for row 1" documenting per-account primary + central bootstrap in aft-mgmt, per-account CMK with cross-account `AtmosReadAllStateRole` grant, `use_lockfile = true` (no DDB), and the two module extensions needed (`source_policy_documents` for S3, sibling `aws_kms_key_policy` for KMS) that `cloudposse/terraform-aws-tfstate-backend` v1.9.0 does not expose natively. Rewrote row 1's purpose + notes columns to point at §2.6. Cross-refs `atmos-model.md` §9.3 and `gha-design.md` §5.8/§12.
- 2026-04-20 — Post-#9 housekeeping (aws-architect re-review): Added row 48 for `tfstate-backend-central` (aft-mgmt-only bootstrap bucket, same `cloudposse/terraform-aws-tfstate-backend` v1.9.0 backing as row 1 but distinct component). Renamed §2.6.2's component reference from `tfstate-backend-bootstrap` to `tfstate-backend-central` to match `atmos-model.md` §9.3.3 step 1. Updated §3 component layout: replaced `account-request-backend/` with `tfstate-backend/` (row 1) and added `tfstate-backend-central/` (row 48).
- 2026-04-20 — Task #10: Expanded row 25 (`iam-roles-target-account`) to state that `AtmosDeploymentRole` lives in all five account classes (CT-mgmt, AFT-mgmt, audit, log-archive, vended), not only vended. CT-core placements stamped by `bootstrap.yaml` §5.8 step 5 via `_bootstrap-target.yaml` with `OrganizationAccountAccessRole` fallback; trust policy template + `sts:ExternalId` guardrail documented in `gha-design.md §4.6`. §3 comment for `iam-roles-target-account/` updated accordingly.
