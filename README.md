# atmos-aft

A replacement for [AWS Control Tower Account Factory for Terraform (AFT)](https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html) built on [Cloudposse Atmos](https://atmos.tools/) and GitHub Actions.

atmos-aft keeps the AFT feature surface — account vending, baseline, feature options, global and per-account customizations, drift detection — and swaps the runtime substrate. AWS CodeBuild + CodePipeline + Step Functions + DynamoDB + Lambda become GitHub Actions workflows, Atmos stack configuration, and Git.

> **Status:** Phase 2 complete. This README is reconciled against the shipped `.github/workflows/`, `components/terraform/`, and `stacks/` trees. See `docs/architecture/` for the source-of-truth design specs.

---

## Table of contents

1. [Overview](#1-overview)
2. [Architecture](#2-architecture)
3. [Prerequisites](#3-prerequisites)
4. [Quickstart](#4-quickstart)
5. [Inputs](#5-inputs)
6. [Outputs](#6-outputs)
7. [Modules and components](#7-modules-and-components)
8. [Providers and versions](#8-providers-and-versions)
9. [Customization layers](#9-customization-layers)
10. [Migration from AFT](#10-migration-from-aft)
11. [Operations](#11-operations)
12. [Security](#12-security)
13. [Troubleshooting](#13-troubleshooting)
14. [Contributing and license](#14-contributing-and-license)

---

## 1. Overview

### What atmos-aft is

A GitOps account factory for AWS Control Tower environments. An account request is a YAML file under `stacks/orgs/<org>/<tenant>/<account>/`. Merge a PR, and GitHub Actions drives the account through vending, baseline, feature options, customizations, and post-provision hooks. Drift is detected daily. Destroys are a separate deliberate workflow with an approval gate.

### How it differs from upstream AFT

| Dimension | AWS AFT | atmos-aft |
|-----------|---------|-----------|
| CI/CD substrate | CodeBuild + CodePipeline | GitHub Actions (OIDC-authenticated) |
| Orchestration | Step Functions (4 SFNs, custom states) | GHA workflow `needs:` DAGs |
| Account request inbox | DynamoDB `aft-request` + stream | Stack YAML in Git |
| Request metadata | 4 DynamoDB tables | `atmos describe stacks` + SSM `/aft/account/<name>/*` |
| Lifecycle events | EventBridge + Lambda polling | EventBridge → GitHub `repository_dispatch` |
| State backend | One shared S3 bucket + DynamoDB lock | Per-account S3 + per-account CMK + S3-native locking (`use_lockfile=true`) |
| Concurrency throttling | FIFO SQS + Lambda poller | GHA `concurrency:` groups + matrix caps |
| Config templating | Jinja2 rendering of `backend.tf` / `providers.tf` | Atmos-native per-stack backend + auth resolution |
| Runner network | Private VPC + 17 endpoints | Public or self-hosted GHA runners (OIDC replaces in-VPC IAM) |
| Drift detection | None | Daily via `drift-detection.yaml` |
| PR plan surface | None | Every PR plans every affected instance; read-only IAM role |
| Forbidden-resource guard | None | OPA policy blocks `aws-organization`, `aws-organizational-unit`, `aws-account` |

### CT coexistence contract

Control Tower owns the Organization, OUs, baseline guardrail SCPs, the org-level CloudTrail, and Identity Center bootstrap. atmos-aft never touches those. atmos-aft adds everything CT doesn't: custom SCPs, per-member security-service configuration, per-account baselines, customizations, feature options. See [`docs/architecture/review.md`](docs/architecture/review.md) for the full CT-ownership matrix.

---

## 2. Architecture

Three design docs are the source of truth; this section is a pointer.

| Doc | Scope |
|-----|-------|
| [`docs/architecture/aft-analysis.md`](docs/architecture/aft-analysis.md) | What upstream AFT does, module by module. Ground truth for parity. |
| [`docs/architecture/atmos-model.md`](docs/architecture/atmos-model.md) | Atmos concepts and the proposed repo layout. |
| [`docs/architecture/mapping.md`](docs/architecture/mapping.md) | AFT artefact → atmos-aft replacement, one row per upstream module/SFN/Lambda/DDB-table. |
| [`docs/architecture/gha-design.md`](docs/architecture/gha-design.md) | GitHub Actions workflow topology (9 reusable + 11 entry-point workflows, 6 composite actions). |
| [`docs/architecture/module-inventory.md`](docs/architecture/module-inventory.md) | Every component, its backing Cloudposse module (or "custom"), and target account. |
| [`docs/architecture/review.md`](docs/architecture/review.md) | aws-architect phase-1 review with the resolved blockers. |

### High-level flow (account creation)

```
PR merged to main (adds stacks/orgs/<org>/<tenant>/<account>/<region>.yaml)
  └─ push-main.yaml classifies the change
       └─ provision-account.yaml
            1. account-provisioning        (CT Account Factory via Service Catalog)
            2. publish-account-id          (SSM /aft/account/<name>/account-id)
            3. tfstate-backend (bootstrap) (first-touch via AWSControlTowerExecution)
            4. iam-roles/target            (stamps AtmosDeploymentRole)
            5. account-baseline            (password policy, EBS encryption, …)
            6. feature-options             (delete default VPCs, enterprise support, CloudTrail)
            7a. config-rules
            7b. guardduty                  ┐
            7c. security-hub               │ sequential; each = _apply-security-service.yaml
            7d. inspector2                 ┘ with skip_if_already_applied=true → phase 3 only
            8. custom-provisioning-hook    (operator extension point)
            9. customize-global
           10. customize-account           (only if vars.customization_name set)
           11. publish-status              (SSM status=customized)
           12. notify                      (optional SNS echo via workflow_run)
```

### Security-service phased rollout

GuardDuty, Security Hub, and Inspector2 are each delegated through three phases, and each phase lives in a different stack — this is why jobs 7b/7c/7d use `skip_if_already_applied=true` and run against the vended stack only:

| Phase | Stack | Component role | What it does |
|-------|-------|----------------|--------------|
| 1 | `core-gbl-mgmt` | `*-root` or `organization-settings` | Enables the org-level service from CT-mgmt and delegates admin to the audit account. |
| 2 | `core-gbl-audit` | `*-delegated-admin` | Configures the organization aggregator/finding-publisher in the delegated-admin account. |
| 3 | every vended stack (e.g. `plat-use1-dev`) | `*-member-settings` | Applies per-member detector/standard configuration. |

Phases 1 and 2 are one-time infrastructure (run during bootstrap, then rarely touched). Phase 3 runs on every vended account via `provision-account.yaml`. The GHA matrix sequences phase 3 against the phase-2 instance so a new member never enrols before the org-admin is ready.

---

## 3. Prerequisites

Before running atmos-aft's bootstrap:

1. **AWS Control Tower landing zone** deployed and `ACTIVE`. ct-management, log-archive, and audit accounts exist. OUs are created via CT.
2. **AFT management account** provisioned through CT Account Factory (name suggestion: `AFT-Management` in a dedicated OU). Single-account topology — where CT-mgmt doubles as AFT-mgmt — is supported with the `separate_aft_mgmt_account=false` bootstrap input, but a dedicated account is recommended.
3. **GitHub organization and repository** hosting this codebase. Repository variables set:
   - `ATMOS_CENTRAL_ROLE_ARN` — ARN of `AtmosCentralDeploymentRole` (written by bootstrap).
   - `AFT_AUTH_MODE` — `oidc` (default) or `access_key` (dev-only).
   - `ATMOS_EXTERNAL_ID` — static UUID used as `sts:ExternalId` when assuming CT-core roles.
4. **GitHub OIDC provider** in AFT-mgmt (`arn:aws:iam::<aft-mgmt>:oidc-provider/token.actions.githubusercontent.com`). Provisioned by the `bootstrap.yaml` workflow on first run.
5. **A bootstrap identity** with programmatic AWS credentials sufficient to create the OIDC provider and the central deployment role on first run. This is used exactly once, then rotated out. See `gha-design.md` §4.5 for the exact permissions.
6. **Service Catalog Account Factory portfolio** shared with AFT-mgmt (handled by `iam-roles-management`'s `associate_aft_service_role_with_account_factory` step if missing).
7. **CloudTrail Lake event data store** in the audit account, or provision via the `cloudtrail-lake` component during bootstrap.

### Supported regions

atmos-aft must run in the CT home region. Multi-region workloads are supported inside each account via the standard Atmos region mixin (`stacks/mixins/region/*.yaml`).

---

## 4. Quickstart

Workflow and stack references below are reconciled against the shipped `.github/workflows/` (#21) and `stacks/` catalog + orgs tree (#17). See `docs/architecture/gha-design.md` §4 and `atmos-model.md` §7 for design detail.

### 4.1 Clone and bootstrap

```bash
git clone git@github.com:<your-org>/atmos-aft.git
cd atmos-aft

# Install Atmos (or use the setup-atmos composite action in CI)
brew install cloudposse/tap/atmos      # macOS
# or: go install github.com/cloudposse/atmos/cmd/atmos@latest

atmos version
atmos list stacks
```

### 4.2 Run the bootstrap workflow

From the GitHub UI, trigger `bootstrap.yaml`:


- `aft_mgmt_account_id`: ID of your AFT management account (or CT-mgmt if single-account).
- `aft_mgmt_region`: CT home region.
- `separate_aft_mgmt_account`: `true` if AFT runs in a dedicated account (default).
- `terraform_distribution`: `oss` (default) or `tfc`.

The workflow runs once and produces:

- `github-oidc-provider` in AFT-mgmt.
- `AtmosCentralDeploymentRole`, `AtmosPlanOnlyRole`, and `AtmosReadAllStateRole` in AFT-mgmt (all OIDC-trusted).
- `AtmosDeploymentRole` stamped in the CT-core accounts (CT-mgmt, AFT-mgmt, audit, log-archive) via `_bootstrap-target.yaml`, using `OrganizationAccountAccessRole` as the bootstrap identity. When `separate_aft_mgmt_account=false`, CT-mgmt doubles as AFT-mgmt and only three accounts are stamped.
- Central bootstrap state bucket (`tfstate-backend-central`) and per-core-account primary `tfstate-backend` instances.
- Security-service delegation for GuardDuty, Security Hub, and Inspector2 (phases 1+2 only — empty `target_stacks` at bootstrap time, no members yet).

### 4.3 Request your first account

Create `stacks/orgs/<your-org>/<tenant>/<stage>/<region>.yaml`. Stack name is rendered as `{tenant}-{region-short}-{stage}` (example: `plat-use1-dev`). A working leaf stack from the shipped `example-accounts` tree:

```yaml
import:
  - orgs/example-accounts/_defaults
  - mixins/tenant/plat
  - mixins/region/us-east-1
  - mixins/stage/dev
  - catalog/account-classes/vended
  - catalog/account-provisioning/defaults
  - catalog/tfstate-backend/defaults
  - catalog/iam-deployment-roles/target/defaults
  - catalog/aws-account-settings/defaults
  - catalog/guardduty-member-settings/defaults

vars:
  account_name: plat-dev
  account_email: aws+plat-dev@acme.example
  managed_organizational_unit: Sandbox
  sso_user_email: platform-oncall@acme.example
  sso_user_first_name: Platform
  sso_user_last_name: Dev
  account_tags:
    owner: team-platform
    cost_center: CC-9000
    stage: dev
  feature_options:
    delete_default_vpcs_enabled: true
    enterprise_support: false
    cloudtrail_data_events: false
  # Optional: selects components/terraform/customizations/<name>/ for job 10.
  # account_customizations_name: standard-web
```

The `catalog/account-classes/<class>` import picks the account's baseline identity — `vended` (CT-vended workloads), `aft-mgmt`, `ct-mgmt`, `audit`, or `log-archive`. Each class bundles defaults for `iam-deployment-roles`, the security services, and (for CT-core accounts) the CT-coexistence flags.

Open a PR. CI runs `pr.yaml` and plans every affected instance read-only. Merge, and `push-main.yaml` dispatches `provision-account.yaml`. End-to-end typically 15–30 minutes, dominated by CT Account Factory.


### 4.4 Watch progress

```bash
gh run watch                                             # most recent run
aws ssm get-parameter --name /aft/account/my-first-account/status   # provisioning | baseline-deployed | customized | failed
```

---

## 5. Inputs

Inputs in atmos-aft split across three surfaces:

- **Factory-level** — repository variables and secrets. Set once per deployment.
- **Stack vars** — per-account configuration in `stacks/orgs/.../<account>/<region>.yaml`.
- **Workflow inputs** — `workflow_dispatch` arguments for entry-point workflows (e.g. `provision-account.yaml`).

### 5.1 Factory-level (repo variables and secrets)


| Name | Location | Type | Default | Notes |
|------|----------|------|---------|-------|
| `ATMOS_CENTRAL_ROLE_ARN` | repo var | string | — | Written by bootstrap; consumed by every deploy workflow. |
| `ATMOS_EXTERNAL_ID` | repo secret | string (UUID) | — | Matched by `sts:ExternalId` on CT-core role trust. |
| `AFT_AUTH_MODE` | repo var | `oidc`\|`access_key` | `oidc` | `access_key` is dev-only and gated by branch protection. |
| `AFT_BOOTSTRAP_ACCESS_KEY_ID` | repo secret | string | — | Used only by `bootstrap.yaml` on first run. |
| `AFT_BOOTSTRAP_SECRET_ACCESS_KEY` | repo secret | string | — | Paired with the above. Rotate out after bootstrap. |
| `TERRAFORM_CLOUD_TOKEN` | repo secret | string | — | Required when `terraform_distribution=tfc|tfe`. Also sensitive in state. |
| `terraform_org_name` | `bootstrap.yaml` input | string | — | Required when `terraform_distribution=tfc|tfe`. HCP Terraform organisation name; maps to upstream AFT's `terraform_org_name`. |
| `terraform_project_name` | `bootstrap.yaml` input | string | `Default Project` | Required when `terraform_distribution=tfc|tfe`. HCP Terraform project containing atmos-aft workspaces; used in the OIDC `sub` claim condition on `AtmosCentralDeploymentRole`. Must exist pre-deploy. Maps to upstream AFT's `terraform_project_name`. |
| `AFT_PROVISION_PARALLELISM` | repo var | number | `1` | Global single-lane default; widened in phase 2 after validation. |
| `AFT_CUSTOMIZE_PARALLELISM` | repo var | number | `4` | Per-scope matrix `max-parallel`. |

### 5.2 Stack vars (per account)

The common vars — these mirror AFT's `control_tower_parameters` plus atmos-aft additions. The authoritative schema lives in the `account-provisioning` component (`components/terraform/account-provisioning/variables.tf`); `stacks/catalog/account-provisioning/defaults.yaml` wires in the SSM-publish hook.

| Name | Type | Required | Default | Notes |
|------|------|:--------:|---------|-------|
| `account_name` | string | yes | — | CT-visible account name. Must be unique in the org. |
| `account_email` | string | yes | — | Root-account email. Must be unique globally. |
| `managed_organizational_unit` | string | yes | — | Target CT OU. |
| `sso_user_email` | string | no | `account_email` | CT SSO user created on account enrolment. |
| `sso_user_first_name` | string | no | derived | |
| `sso_user_last_name` | string | no | derived | |
| `account_tags` | map(string) | no | `{}` | Applied via Organizations tag-resource. |
| `account_customizations_name` | string | no | `null` | Selects `components/terraform/customizations/<name>/` for step 10. Null means global-only. |
| `change_management_parameters` | map(any) | no | `null` | Opaque; surfaced to the custom-provisioning hook. |
| `custom_fields` | map(any) | no | `null` | Opaque; surfaced to global + account customizations via `!store`. |
| `feature_options` | object | no | see below | |

`feature_options` defaults (object):

| Field | Type | Default | Notes |
|-------|------|---------|-------|
| `delete_default_vpcs_enabled` | bool | `false` | Deletes default VPC in every region. Upstream AFT: `aft_feature_delete_default_vpcs_enabled`. |
| `enterprise_support` | bool | `false` | Enrols in AWS Enterprise Support (requires payer eligibility). |
| `cloudtrail_data_events` | bool | `false` | Enables CloudTrail data events (S3, Lambda object-level). |

### 5.3 Workflow inputs

Per entry-point workflow. Full list in `docs/architecture/gha-design.md` §3. The ones an operator runs by hand:

| Workflow | Key inputs | When to use |
|----------|------------|-------------|
| `bootstrap.yaml` | `aft_mgmt_account_id`, `aft_mgmt_region`, `separate_aft_mgmt_account`, `terraform_distribution` | One-time initial deploy. |
| `provision-account.yaml` | `stack`, `skip_customizations`, `skip_feature_options` | Manual re-run of an account's provisioning DAG. |
| `customize-fleet.yaml` | `scope` (`all`\|`changed`\|`stack:<name>`\|`component:<c>`), `dry_run` | Run customizations across the fleet on demand. |
| `destroy-account.yaml` | `stack`, `confirm_account_id` | Deliberate account teardown. Environment-gated. |
| `import-existing-account.yaml` | `stack`, `servicecatalog_provisioned_product_id` | Bring an existing CT account under atmos-aft management. |
| `drift-detection.yaml` | — | Manual trigger of the daily drift scan. |

### 5.4 Inputs dropped from upstream AFT

Intentional cuts; these have no analogue in atmos-aft:

| Upstream AFT input | Replacement |
|--------------------|-------------|
| `aft_enable_vpc`, `aft_vpc_endpoints`, `aft_vpc_cidr`, `aft_vpc_*_subnet_*_cidr`, `aft_customer_vpc_id`, `aft_customer_private_subnets` | No AFT VPC — GHA runners replace the in-VPC CodeBuild. Self-hosted runners remain an option for air-gapped environments. |
| `aft_codebuild_compute_type`, `global_codebuild_timeout` | GHA runner tier is controlled in `.github/workflows/*.yml`. |
| `concurrent_account_factory_actions` | `AFT_PROVISION_PARALLELISM` repo variable; per-concurrency-group. |
| `terraform_oidc_*` | Replaced by GitHub OIDC (first-class; `terraform_oidc_integration` becomes trivially `true` when using TFC). |
| `backup_recovery_point_retention` | Not applicable — no AFT-owned DynamoDB tables (DDB dropped per design decision #8; replaced by Git + SSM as the request + metadata plane). |
| `tf_backend_secondary_region` | Not applicable — atmos-aft is single-region in Phase 1 per `docs/architecture/atmos-model.md` §9.3.4. State replication is a per-account bucket opt-in, not a global toggle. |
| `cloudwatch_log_group_enable_cmk_encryption`, `sns_topic_enable_cmk_encryption` | Uniformly CMK-encrypted. No AWS-managed-key fallback. |

Per-input parity is audited in [`docs/architecture/readme-audit.md`](docs/architecture/readme-audit.md).

---

## 6. Outputs

atmos-aft exposes state via three surfaces:

### 6.1 SSM parameters (`/aft/*` namespace)

Written by the `publish-status` and `publish-account-id` composite actions; consumed by downstream components via Atmos's `!store` YAML function.

| Parameter | Source | Notes |
|-----------|--------|-------|
| `/aft/account/<name>/account-id` | `provision-account.yaml` job 2 | Populated on first successful vend. |
| `/aft/account/<name>/status` | `provision-account.yaml` job 11; `destroy-account.yaml` | `provisioning` → `baseline-deployed` → `customized` → (`drift`\|`destroyed`\|`failed`). |
| `/aft/account/<name>/ou` | `provision-account.yaml` job 1 | Tracks current OU. |
| `/aft/config/terraform/version` | `aft-ssm-parameters` catalog | TF version pinned per deployment. |
| `/aft/config/terraform/distribution` | `aft-ssm-parameters` | `oss` \| `tfc` \| `tfe`. |
| `/aft/resources/backend/bucket` | `tfstate-backend-central` | Central bootstrap bucket name. |
| `/aft/resources/backend/kms-key-alias` | `tfstate-backend-central` | CMK alias. |

### 6.2 Atmos stack outputs

`atmos describe component <c> -s <stack>` returns any Terraform output of the component. Frequently needed:

- `account-provisioning` → `account_id`, `account_email`, `ou_id`.
- `tfstate-backend` → `bucket_id`, `kms_key_arn`.
- `iam-roles/target` → `deployment_role_arn`.

### 6.3 Workflow artifacts

- **Plan summaries** — `post-plan-summary` composite posts per-instance diffs to the PR and to `$GITHUB_STEP_SUMMARY`.
- **Planfiles** — stored via the Atmos planfile store (S3-backed; keys under `planfiles/<run-id>/<stack>/<component>.tfplan`).
- **Drift reports** — `drift-detection.yaml` opens a GitHub issue per drifting instance, labelled `drift`.

### 6.4 Outputs dropped vs upstream

Input-echo outputs from upstream AFT (e.g. `ct_home_region` re-exposing `var.ct_home_region`) have no equivalent; stack config is already visible. Runtime coordinates (bucket IDs, role ARNs, CMK aliases) are reachable via `atmos describe` or SSM as listed above.

---

## 7. Modules and components

See [`docs/architecture/module-inventory.md`](docs/architecture/module-inventory.md) for the exhaustive table.

### 7.1 Repo layout

```
atmos-aft/
├── atmos.yaml                # Project config: paths, auth chain, stores, CI, schemas
├── vendor.yaml               # Upstream component sources (go-getter)
├── Makefile
├── components/terraform/
│   ├── account-provisioning/            # Custom — CT Account Factory wrapper
│   ├── iam-deployment-roles/{central,target}/   # Custom — central + per-account role set
│   ├── controltower-event-bridge/       # Custom — CT event → GH repository_dispatch
│   ├── cloudtrail-lake/                 # Custom — audit event store
│   ├── cloudtrail-additional/           # Custom — per-account supplementary trails
│   ├── tfstate-backend/ + tfstate-backend-central/   # Per-account + bootstrap backends
│   ├── aft-access-logs-bucket/ aft-lifecycle-lambdas/ aft-observability/ aft-ssm-parameters/
│   ├── account-request-{kms,queue,notifications}/   # Request-plane infra
│   ├── aws-account-settings/            # Custom — password policy + EBS encryption defaults
│   ├── aws-budgets/ aws-scp/            # Cloudposse wrappers
│   ├── aws-config-rules/ aws-config-conformance-pack/   # CT-compat Config extensions
│   ├── guardduty-root/ guardduty-delegated-admin/ guardduty-member-settings/
│   ├── security-hub/ inspector2/        # Delegated-admin + member via stack class
│   ├── identity-center-permission-sets/ identity-center-assignments/
│   ├── github-oidc-provider/            # Custom
│   ├── centralized-logging-bucket/ cloudwatch-log-groups/ vpc-flow-logs-bucket/
│   ├── dns-primary/ dns-delegated/ ipam/
│   └── customizations/<name>/           # Per-account customization modules (operator-owned)
├── stacks/
│   ├── catalog/
│   │   ├── account-classes/{vended,aft-mgmt,ct-mgmt,audit,log-archive}.yaml
│   │   └── <component>/defaults.yaml
│   ├── mixins/{region,tenant,stage}/<x>.yaml
│   ├── orgs/
│   │   ├── _defaults.yaml
│   │   └── <org>/
│   │       ├── _defaults.yaml
│   │       └── <tenant>/<stage>/<region>.yaml   # Leaf stacks
│   ├── workflows/                       # Atmos workflows (provision-account, drift, destroy)
│   └── schemas/{jsonschema,opa}/
├── tests/{opa,terratest,act}/
├── vendor/                              # Populated by `atmos vendor pull`
├── .github/
│   ├── actions/<name>/action.yml        # 6 composite actions
│   ├── workflows/<name>.yml             # 11 reusable + 12 entry-point
│   ├── policies/*.rego                  # OPA policies
│   └── CODEOWNERS
├── scripts/
│   └── import-existing-accounts.sh
└── docs/architecture/                   # Design specs (source of truth)
```

The full component list is longer than what fits here; see [`docs/architecture/module-inventory.md`](docs/architecture/module-inventory.md) for every component with its backing Cloudposse module (or "custom") and its target account.

### 7.2 Stack naming

Stack name is rendered from `{tenant}-{environment}-{stage}` (example: `plat-use1-dev`). `environment` follows the Cloudposse null-label convention — the field name is `environment`, its value is a region short-code (`use1` for `us-east-1`, `usw2` for `us-west-2`, `gbl` for account-global).

Required inheritance chain:

```
stacks/orgs/_defaults.yaml                    (top-level — backend config)
└─ stacks/orgs/<org>/_defaults.yaml           (org — namespace, tags, settings)
   └─ stacks/orgs/<org>/<tenant>/<stage>/<region>.yaml (leaf, one file per region)
```

Each leaf stack imports the org `_defaults`, its tenant/stage/region mixins, the relevant account-class, and the components it needs. The shipped `example-accounts` tree renders six stacks:

| Stack | Leaf file | Class |
|-------|-----------|-------|
| `aft-gbl-mgmt` | `aft/aft-mgmt/gbl.yaml` | `aft-mgmt` |
| `core-gbl-mgmt` | `core/ct-mgmt/gbl.yaml` | `ct-mgmt` |
| `core-gbl-audit` | `core/audit/gbl.yaml` | `audit` |
| `core-gbl-log-archive` | `core/log-archive/gbl.yaml` | `log-archive` |
| `plat-use1-dev` | `plat/dev/us-east-1.yaml` | `vended` |
| `plat-use1-prod` | `plat/prod/us-east-1.yaml` | `vended` |

Components inherit through `metadata.inherits`.

### 7.3 Custom vs Cloudposse

Seven custom components (not backed by a Cloudposse module): `account-provisioning`, `iam-deployment-roles` (with `central` and `target` instances), `controltower-event-bridge`, `cloudtrail-lake`, `tfstate-backend-central`, `aws-account-settings`, `github-oidc-provider`. Everything else wraps a Cloudposse `terraform-aws-components` module; see `module-inventory.md` for versions.

### 7.4 Forbidden components

| Cloudposse module | Reason | Alternative |
|-------------------|--------|-------------|
| `terraform-aws-organization` | CT owns Organizations | `data "aws_organizations_organization"` |
| `terraform-aws-organizational-unit` | CT vends OUs | `data "aws_organizations_organizational_units"` |
| `terraform-aws-account` | Bypasses CT guardrails | `account-provisioning` (Service Catalog wrapper) |
| `terraform-aws-cloudtrail` (org scope) | CT owns the org trail | Permitted only for per-account supplementary trails |

Enforced by `.github/policies/forbidden-components.rego` at PR time.

---

## 8. Providers and versions

| Tool | Version | Notes |
|------|---------|-------|
| Atmos | `>= 1.88.0` | Pinned in `atmos.yaml`; resolved by `setup-atmos` composite action. |
| Terraform | `>= 1.10.0, < 2.0.0` | 1.10 required for S3-native state locking. |
| AWS provider | `>= 6.0.0, < 7.0.0` | Matches upstream AFT. |
| GitHub Actions runner | `ubuntu-24.04` | Self-hosted supported but not required. |
| `gh` CLI | `>= 2.40` | Used by composite actions. |
| `jq`, `yq` | pinned in `install-gha-cli-deps` composite | |

Required GitHub features:

- **Actions** enabled (obviously).
- **OIDC** enabled in the repo (`id-token: write` permission in workflows).
- **Environments** with approval gates: `prod`, `aft-mgmt`, `destroy`.
- **Branch protection** on `main`: required checks = `pr.yaml`, approver review, no force-push.
- **Repository dispatch** enabled for `ct-lifecycle-event.yaml` (inbound from EventBridge API destination).

---

## 9. Customization layers

atmos-aft preserves AFT's three-layer customization model plus one new extension point.

### 9.1 Global customizations

Applied to **every** AFT-managed account after baseline. Lives in `components/terraform/customizations/global/`. Applied by `_customize-global.yaml` reusable workflow. State key per account: `$VENDED_ACCOUNT_ID-aft-global-customizations/terraform.tfstate`.

Typical contents: org-wide IAM policies, standard tags, CloudWatch log forwarder, baseline SSM documents.

### 9.2 Per-account customizations

Applied only when the stack's `vars.account_customizations_name` is set. Lives in `components/terraform/customizations/<name>/`. Applied by `_customize-account.yaml`. State key: `$VENDED_ACCOUNT_ID-aft-account-customizations/terraform.tfstate`.

Pattern: each `<name>` is a self-contained Terraform module with its own `terraform/` and optional `api_helpers/` (pre/post shell hooks). No Cloudposse module — the content is customer IP.

### 9.3 Provisioning-time customizations hook

`custom-provisioning-hook.yaml` is the equivalent of AFT's customer-owned `aft-account-provisioning-customizations` Step Function. Fires after feature options and before global customizations (job 8 of `provision-account.yaml`). Defaults to no-op; operators override by editing the workflow.

Typical contents: ServiceNow ticket creation, approval gate, compliance tagging, internal CMDB write.

### 9.4 Post-provision hook

`_post-provision-hook.yaml` is the outbound signal — runs after `publish-status` and can trigger downstream systems (Slack, Jira, DataDog). Left as a no-op stub; operators wire up as needed.

### 9.5 Lifecycle events from Control Tower

CT emits `CreateManagedAccount`, `UpdateManagedAccount`, and `RegisterOrganizationalUnit` events on the CT-mgmt default bus. atmos-aft routes these to a custom bus in AFT-mgmt → API Destination → GitHub `repository_dispatch` → `ct-lifecycle-event.yaml`. Operators can hook into this workflow to react to CT-initiated changes (account moves, OU registrations) that were not triggered by a merge to this repo.

---

## 10. Migration from AFT

For teams currently running upstream AFT. The migration is incremental; both systems can run side-by-side during cut-over.

**See [`docs/architecture/migration-from-aft.md`](docs/architecture/migration-from-aft.md) for the full migration playbook.** The standalone doc covers pre-migration audit, side-by-side bootstrap, account-by-account import, customization migration (including the SFN → GHA construct map), special cases, AFT decommissioning, rollback, the full artefact mapping table, and time estimates.

Summary of the migration path:

1. **Audit** — inventory AFT-managed accounts, customizations, SSM parameters, inputs, and in-flight state.
2. **Side-by-side bootstrap** — stand up atmos-aft in the same AFT-mgmt account. Different IAM role names, separate state backends, no DDB tables. AFT keeps operating.
3. **Account-by-account import** — for each account: author stack YAML, run `scripts/import-existing-accounts.sh`, run `import-existing-account.yaml`, verify zero-diff plan, decommission from AFT.
4. **Customization migration** — customer-owned Terraform ports directly. Backend Jinja files are deleted (atmos-aft renders natively). The `aft-account-provisioning-customizations` SFN is rewritten as GHA jobs.
5. **Decommission AFT** — once the last account is migrated, destroy AFT's Terraform root module, remove the `AWSAFT*` roles, archive the AFT state bucket.

Rollback is documented in [`migration-from-aft.md`](docs/architecture/migration-from-aft.md) §8 — atmos-aft is non-destructive up to the AFT-decommission step.

---

## 11. Operations

### 11.1 Adding an account

PR a new `stacks/orgs/<org>/<tenant>/<account>/<region>.yaml`. Merge. That's it. See [§4.3](#43-request-your-first-account).

### 11.2 Updating an account

Edit the stack YAML. PR runs `atmos terraform plan` on every affected instance. Merge to apply. Changes to `control_tower_parameters` (OU move, SSO user change) trigger a re-provision path; other changes trigger customization-only runs.

### 11.3 Destroying an account

```
gh workflow run destroy-account.yaml \
  --field stack=plat-use1-dev \
  --field confirm_account_id=123456789012
```

Requires approval from the `destroy` GitHub environment. Workflow suspends the Service Catalog product, polls Organizations until the account is in `SUSPENDED` state (up to 45 min), then writes `status=destroyed` to SSM. A seven-day cooldown applies before the same account name/email can be re-requested.

### 11.4 Running customizations on demand

```
gh workflow run customize-fleet.yaml --field scope=all
gh workflow run customize-fleet.yaml --field scope=changed       # based on git diff since last run
gh workflow run customize-fleet.yaml --field scope=stack:plat-use1-dev
```

Also scheduled every Monday 06:00 UTC.

### 11.5 Drift detection

`drift-detection.yaml` runs daily at 02:00 UTC. The `list` job enumerates `(component, stack)` pairs via `AtmosReadAllStateRole` (decrypt-only, cross-account read access to every state bucket). Each pair then fans out into a matrix of `atmos terraform plan` jobs that assume `AtmosPlanOnlyRole` in the central account and chain into `AtmosDeploymentRoleReadOnly` in the target — read-only end-to-end, no write surface on either hop. Drift is surfaced in the workflow step summary (per-pair plan results aggregated by the matrix).

To run on demand:

```
gh workflow run drift-detection.yaml
```

### 11.6 Vendor refresh

`vendor-refresh.yaml` runs `atmos vendor pull` weekly (Monday 03:00 UTC) and opens a PR with any upstream changes to Cloudposse components. Reviewers audit the diff and merge; breaking changes get a separate task.

### 11.7 Bootstrapping a new region

Add the region mixin to the stack and run `customize-fleet.yaml --scope=stack:<new-stack>`. `tfstate-backend` creates a new per-account bucket in the new region automatically.

### 11.8 Atmos CLI reference (local dev)

| Command | Purpose |
|---------|---------|
| `atmos list stacks` | All top-level stacks. |
| `atmos list components [-s <glob>]` | Components across stacks. |
| `atmos describe stacks --format json` | Full resolved config. |
| `atmos describe component <c> -s <stack>` | Resolved config for one instance. |
| `atmos describe affected --ref <ref> --format json` | Git-diff-aware set of affected instances. Piped into a GHA matrix by the `resolve-stack` composite action. |
| `atmos terraform plan <c> -s <stack> --ci` | Plan with CI job summary. |
| `atmos terraform apply <c> -s <stack>` | Plan + apply. |
| `atmos terraform destroy <c> -s <stack>` | Destroy a single instance. |
| `atmos workflow <name>` | Run an Atmos workflow (see `stacks/workflows/`). |
| `atmos vendor pull [--component <n>]` | Materialise vendored components. |
| `atmos validate stacks` | JSON Schema validation of all stacks. OPA runs per-component via `atmos validate component <c> -s <s>`, or in CI by piping `atmos describe stacks --format json` through `opa eval`. |

---

## 12. Security

### 12.1 IAM trust chain

Two parallel chains, separated by intent:

```
Apply paths (bootstrap, provision-account, customize-*, destroy-account):
GitHub OIDC principal (token.actions.githubusercontent.com)
  └─ sts:AssumeRoleWithWebIdentity (sub claim scoped to this repo + environment)
       → AtmosCentralDeploymentRole (in AFT-mgmt)
            └─ sts:AssumeRole (with sts:ExternalId for CT-core; session=atmos-<workflow>-<run-id>)
                 → AtmosDeploymentRole (in target account)   [AdministratorAccess]

Plan-only paths (pr.yaml, drift-detection.yaml):
GitHub OIDC principal
  └─ sts:AssumeRoleWithWebIdentity
       → AtmosPlanOnlyRole (in AFT-mgmt)
            └─ sts:AssumeRole
                 → AtmosDeploymentRoleReadOnly (in target account)   [ReadOnlyAccess]
```

- **`AtmosCentralDeploymentRole`** has no direct AWS permissions — only `sts:AssumeRole` on `AtmosDeploymentRole` across the org. Defence-in-depth against a leaked OIDC exchange.
- **`AtmosDeploymentRole`** has `AdministratorAccess` in its own account. Its trust policy permits only `AtmosCentralDeploymentRole` plus (for CT-core accounts) a matching `sts:ExternalId`.
- **`AtmosPlanOnlyRole`** — central-hub role used by `pr.yaml` and `drift-detection.yaml`. Carries only `sts:AssumeRole` on `AtmosDeploymentRoleReadOnly` across the org; cannot assume any write role. The chain is wired through `_atmos-plan.yaml`'s `central_role_arn` and `target_role_name` inputs: `resolve-stack` composes `target_role_arn = arn:aws:iam::<account_id>:role/<target_role_name>`, `configure-aws` exports it as `TF_VAR_target_role_arn`, and every component's `provider "aws" { dynamic "assume_role" { ... } }` block assumes the read-only target role.
- **`AtmosDeploymentRoleReadOnly`** — stamped in every target account by the same bootstrap flow as `AtmosDeploymentRole`. Attached `ReadOnlyAccess` + `organizations:Describe*`. Trust policy permits only `AtmosPlanOnlyRole`.
- **`AtmosReadAllStateRole`** — decrypt-only cross-account role used by `drift-detection.yaml`'s `list` job (state enumeration). Scoped by `kms:ViaService` to `s3.*.amazonaws.com`.

All PR runs use the standard `pull_request` trigger. Same-repo PRs obtain OIDC credentials for `AtmosPlanOnlyRole` and produce a live plan. PRs from external forks receive no AWS credentials (GitHub withholds secrets by default on fork PRs) and produce only a static `atmos describe affected` summary. A maintainer can close-reopen the PR from a trusted branch to trigger a live plan. atmos-aft never uses `pull_request_target`, which would run workflow code against the base-branch context with secrets — the known privilege-escalation vector for fork PRs.

### 12.2 State encryption

Every Terraform state file is encrypted in S3 with a per-account customer-managed CMK (alias `alias/atmos-tfstate`). Key policy admits root + local `AtmosDeploymentRole` (full use) + local `AtmosDeploymentRoleReadOnly` (decrypt only) + `AtmosCentralDeploymentRole` (full use, for bootstrap) + `AtmosReadAllStateRole` (decrypt only, conditioned on `kms:ViaService = s3.*.amazonaws.com`).

Bucket policies enforce `aws:SecureTransport` and deny unencrypted PutObject.

State locking is S3-native (Terraform ≥ 1.10 with `use_lockfile=true`). No DynamoDB lock table.

### 12.3 CT coexistence guarantees

atmos-aft never manages:

- The Organization or any OU.
- CT's baseline guardrail SCPs.
- CT's org-level CloudTrail trail.
- CT's Config recorder or Config IAM role. `aws-config` catalog defaults hardcode `create_recorder=false` and `create_iam_role=false`.
- CT's Identity Center instance (permission sets and assignments are layered on top).

Enforced by `.github/policies/forbidden-components.rego` and catalog defaults. Violations fail `pr.yaml`.

### 12.4 HCP Terraform / TFC OIDC governance

If `terraform_distribution=tfc|tfe`, atmos-aft configures `AtmosCentralDeploymentRole` with a second OIDC trust for HCP Terraform. The `sub` claim is scoped to `organization:${org}:project:${project}:workspace:*:run_phase:*`.

**Operator responsibility:** anyone who can create a workspace inside the configured TFC project can assume `AtmosCentralDeploymentRole`. Use a dedicated TFC project exclusively for atmos-aft. Restrict workspace creation to a small team. Audit workspaces regularly. For higher assurance, replace the `workspace:*` wildcard with explicit names (requires maintaining the trust policy outside atmos-aft updates).

### 12.5 Secrets

- `terraform_token` (TFC API) — stored as `TERRAFORM_CLOUD_TOKEN` GitHub secret **and** as SSM `SecureString` for runtime consumers. Both surfaces are encrypted at rest with the AFT CMK.
- No long-lived AWS keys in CI. Bootstrap user keys are used exactly once during `bootstrap.yaml` and should be rotated out.

---

## 13. Troubleshooting

**See [`docs/architecture/troubleshooting.md`](docs/architecture/troubleshooting.md) for the full troubleshooting guide.** It catalogues failure modes by layer (CT preconditions, IAM/OIDC, Service Catalog provisioning, GHA orchestration, Terraform/Atmos, state/locking, customizations), with diagnostic commands, ordered remediations, escalation playbooks, and an error-text → section index.

### 13.1 Quick reference — most common failures

| Symptom | See |
|---------|-----|
| `Service Catalog product not found` during provision | [troubleshooting.md §1.1](docs/architecture/troubleshooting.md) |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | [§2.1](docs/architecture/troubleshooting.md) |
| `AccessDenied` immediately after bootstrap (propagation) | [§2.4](docs/architecture/troubleshooting.md) |
| `ProvisionedProductName already exists` | [§3.1](docs/architecture/troubleshooting.md) |
| CT-concurrency errors when provisioning multiple accounts | [§3.2](docs/architecture/troubleshooting.md) |
| GHA matrix > 256 jobs | [§4.1](docs/architecture/troubleshooting.md) |
| `describe affected` empty when change expected | [§5.1](docs/architecture/troubleshooting.md) |
| OPA blocks plan (`aws-organization` / CT-owned resource) | [§5.3](docs/architecture/troubleshooting.md) |
| `Error acquiring the state lock` | [§6.1](docs/architecture/troubleshooting.md) |
| Drift detection opens an issue every run | [§7.1 + §5.1](docs/architecture/troubleshooting.md) |

### 13.2 Getting diagnostics

```bash
# Account status
aws ssm get-parameter --name /aft/account/<name>/status --query Parameter.Value

# Last provisioning run
gh run list --workflow=provision-account.yaml --limit=5

# Resolved stack config
atmos describe component account-provisioning -s <stack> --format json

# Drift on a specific instance
atmos terraform plan <component> -s <stack>
```

### 13.3 When to open an issue vs fix in-PR

- **In-PR**: anything reproducible on a fresh clone (stack config, customization Terraform, OPA policy violation).
- **Issue**: infrastructure-level failures (CT landing-zone state, AWS API throttling, Service Catalog portfolio issues) that require operator action outside this repo. See [troubleshooting.md §9.4](docs/architecture/troubleshooting.md) for the full retry-vs-incident decision matrix.

---

## 14. Contributing and license

### 14.1 Contributing

Follow the standard GitHub PR flow. Every PR runs `pr.yaml` which:

- Plans every affected instance (read-only).
- Validates every stack with JSON Schema + OPA.
- Enforces the forbidden-components policy.
- Checks that any new component has a matching `stacks/catalog/<component>/defaults.yaml`.

Design changes go through `docs/architecture/` first. Implementation PRs should link to the design doc they instantiate.

### 14.2 License

Apache 2.0. atmos-aft reuses the license terms of the upstream [AWS AFT reference implementation](https://github.com/aws-ia/terraform-aws-control_tower_account_factory) where relevant. Cloudposse components under `vendor.yaml` retain their own Apache 2.0 license.

See `LICENSE` (top of this repo) and the upstream `reference/aft/LICENSE` for full terms.

---

## References

- [AWS Control Tower Account Factory for Terraform — Overview](https://docs.aws.amazon.com/controltower/latest/userguide/aft-overview.html)
- [Cloudposse Atmos documentation](https://atmos.tools/)
- [Cloudposse `terraform-aws-components`](https://github.com/cloudposse/terraform-aws-components)
- [`docs/architecture/`](docs/architecture/) — full design specs (source of truth for every claim in this README)
