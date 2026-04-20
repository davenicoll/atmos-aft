# AFT → Atmos Mapping

This document maps every concept in `docs/architecture/aft-analysis.md` to an Atmos + GitHub Actions equivalent. It is the bridge between the two reference reads and the eventual Phase 2 implementation. No code yet — the output is a set of components, stack-config shapes, workflow topologies, and a flagged list of things that do not map cleanly.

**Scope and ground rules.** AWS Control Tower stays. The factory coexists with a running CT Landing Zone and must not fight it for ownership of the Organization, OUs, the account-provisioning lifecycle, the org-level CloudTrail, the baseline Config recorder, or any CT-managed guardrail SCP. See §8 for the complete coexistence matrix. Three Cloudposse modules are **forbidden** in this repo on that basis: `aws-organization`, `aws-organizational-unit`, and `aws-account`.

Cross-references:
- AFT source of truth: `docs/architecture/aft-analysis.md` and files under `reference/aft/`.
- Atmos source of truth: `docs/architecture/atmos-model.md` and files under `reference/atmos/`.

The section numbering below mirrors `aft-analysis.md` §1–§7. §8 adds the coexistence matrix. §9 is the "does not map cleanly" list — the explicit input to the GHA workflow design (task #3) and the AWS architect review (task #4).

---

## 1. Top-level modules → Atmos components and GHA workflows

AFT's ten-module root (`aft-analysis.md:9-55`) fans out along two axes: *what infrastructure gets built* (which becomes Atmos components) and *what orchestration runs them* (which becomes GHA workflows). Keeping those axes separate is the single biggest structural change from AFT.

| AFT module | Atmos/GHA equivalent | Owned by |
|---|---|---|
| `packaging` (`main.tf:4-6`) | Not required. Atmos has no Lambda artifacts — there are no `src/aft_lambda/` trees to zip. | — |
| `aft_account_provisioning_framework` (`main.tf:8-37`) | **`atmos workflow provision-account`** (`reference/atmos/website/docs/cli/commands/workflow.mdx`). The SFN's four Lambdas (`create_role`, `tag_account`, `persist_metadata`, `account_metadata_ssm`) become discrete components or steps inside the workflow — see §2. | GHA workflow + Atmos workflow file |
| `aft_account_request_framework` (`main.tf:39-65`) | **Git is the inbox.** The `aft-request` DDB table is replaced by `stacks/orgs/<org>/<ou>/<account>/<region>.yaml` committed to this repo. The DDB stream is replaced by `atmos describe affected --format=matrix` on the PR (`reference/atmos/website/docs/cli/commands/describe/describe-affected.mdx`). SQS throttling is replaced by a GHA `concurrency:` group keyed on the tenant/OU. See §4 for the full state/queue replacement and §9 item 1 for what this costs us. | GHA workflow + repo layout |
| `aft_backend` (`main.tf:67-77`) | **`components/terraform/tfstate-backend/`** (vendor from `cloudposse/terraform-aws-components/modules/tfstate-backend`). One instance per account that holds state; backend config is rendered per-stack by Atmos' `auto_generate_backend_file` (`reference/atmos/website/docs/stacks/backend.mdx`), so no Jinja. See §7. | Atmos component |
| `aft_code_repositories` (`main.tf:79-111`) | Not required. CodeCommit/CodeConnections are replaced by GitHub itself; the CodePipelines are replaced by GHA workflows in `.github/workflows/`. | GHA |
| `aft_customizations` (`main.tf:113-151`) | **Customization components** under `components/terraform/customizations/<name>/` plus two GHA reusable workflows (`customize-global.yaml`, `customize-account.yaml`). The dynamic per-account CodePipeline becomes a `workflow_call` invocation per target, enumerated from `atmos list instances`. See §3. | Atmos components + GHA reusable workflow |
| `aft_feature_options` (`main.tf:153-183`) | Three small components, each gated by a stack var: `delete-default-vpcs/`, `enterprise-support-enrollment/`, `cloudtrail-org-logging/`. They run as a sequenced block inside the provision workflow. Each component is vendored or thin-wraps an existing Cloudposse module. | Atmos components |
| `aft_iam_roles` (`main.tf:185-200`) | **Atmos `auth:` chain** (`reference/atmos/website/docs/stacks/auth.mdx`) plus **`components/terraform/github-oidc-provider/`** and **`components/terraform/iam-deployment-roles/`**. The `AWSAFTAdmin`/`AWSAFTExecution`/`AWSAFTService` three-role chain becomes a GHA OIDC trust → central deployment role → per-account `AtmosDeploymentRole` chain. See §5. | Atmos components + Atmos `auth:` |
| `aft_lambda_layer` (`main.tf:202-226`) | Not required. No Lambdas. | — |
| `aft_ssm_parameters` (`main.tf:228-301`) | **Atmos stores + stack config**. The ~50 `/aft/config/*` params split into: (a) static config that lives in `atmos.yaml` or catalog defaults (Terraform version, module sources, region, log retention, feature toggles); (b) runtime cross-account data that lives in SSM via the `store-outputs` hook (`reference/atmos/website/docs/stacks/hooks.mdx`) and is read via `!store` (`reference/atmos/website/docs/functions/yaml/store.mdx`). See §4.3. | `atmos.yaml` + Atmos stores |

Two new modules that AFT does not have but we must add:

- **`account-provisioning/`** — custom component wrapping `aws_servicecatalog_provisioned_product` against the CT Account Factory portfolio. Covered in §2 and §9 item 2. This is the *only* place in the system that talks to Service Catalog; it replaces AFT's `aft-account-request-processor` Lambda (`reference/aft/src/aft_lambda/aft_account_request_framework/aft_account_request_processor.py:37-133`).
- **Baseline security components** that AFT implicitly gets from CT Landing Zone + customer customizations: `aws-config` (CT-compat flags, see §8), `aws-guardduty/{delegated-admin,root-delegation,org-settings}` (three-phase, see §8), `aws-security-hub`, `aws-inspector`, `iam-identity-center`, `aws-account-settings`, `aws-budget`, `aws-scp`. Not a module-for-module map from AFT — AFT defers these to customer repos, we move them into the factory itself.

---

## 2. Provisioning lifecycle → Atmos workflow + GHA orchestration

AFT's five-phase lifecycle (`aft-analysis.md:59-111`) collapses into three GHA workflows backed by Atmos commands and one Atmos-defined workflow file.

### 2.1 Phase-by-phase mapping

| AFT phase | AFT mechanism | Atmos + GHA equivalent |
|---|---|---|
| **A. Request ingestion** (`aft-analysis.md:63-74`) | Customer TF writes `aws_dynamodb_table_item` to `aft-request`; DDB stream fires `aft-account-request-action-trigger`; router dispatches by INSERT/MODIFY/REMOVE. | Operator opens a PR adding/updating `stacks/orgs/<org>/<ou>/<account>/<region>.yaml`. `atmos describe affected --format=matrix --include-dependents=true` on the PR classifies the change: new stack file = `create`, changed `metadata`/`vars.control_tower_parameters` = `update`, deleted stack file = `destroy`. Routing is the GHA workflow's `if:` on the matrix output, not a DDB stream. |
| **B. Service Catalog provisioning** (`aft-analysis.md:75-78`) | `aft-account-request-processor` Lambda drains SQS, calls `servicecatalog.ProvisionProduct` against the CT Account Factory portfolio, polls for completion. | The provision workflow runs `atmos terraform deploy account-provisioning -s <stack> --ci` (`reference/atmos/website/docs/cli/commands/terraform/deploy.mdx` / `ci.mdx`). The `account-provisioning` component's `aws_servicecatalog_provisioned_product` resource performs the same call; Terraform's resource polling replaces the SQS-drain loop. Concurrency throttling = GHA `concurrency: group: ct-provisioning` (because CT serialises account vending anyway). |
| **C. CT event crossing** (`aft-analysis.md:80-87`) | EventBridge bus `aft-events-from-ct-management`; rule invokes `aft-invoke-aft-account-provisioning-framework` Lambda which resolves account_id and starts the provisioning SFN. | **Not needed.** `aws_servicecatalog_provisioned_product` returns on completion; its outputs include the new account ID. The workflow writes `account_id` to SSM via the `store-outputs` hook (`reference/atmos/website/docs/stacks/hooks.mdx`) so downstream steps in the same workflow (and any later stack) can read it via `!store`. See §9 item 3 for the edge case where Service Catalog returns before CT guardrails are actually enforced. |
| **D. Provisioning framework SFN** (`aft-analysis.md:89-99`) | Seven-state SFN: `persist_metadata` → `create_role` → `tag_account` → `account_metadata_ssm` → `aft_features` → `account_provisioning_customizations` → `run_create_pipeline?` → `notify_success`. | Single Atmos workflow file `stacks/workflows/provision-account.yaml` with named steps: `account-provisioning` → `tfstate-backend` → `iam-deployment-roles` → `aws-account-settings` → baseline security block (`aws-config`, `aws-guardduty/*`, `aws-security-hub`, `aws-inspector`) → `aft-feature-options` equivalents → customization components. Persistence and metadata that AFT stores in DDB become outputs of `account-provisioning` published to SSM via `store-outputs`. See §2.2 below. |
| **E. Customizations pipeline** (`aft-analysis.md:101-107`) | `aft-create-pipeline` materialises `${account_id}-customizations-pipeline`; `aft-invoke-customizations` SFN uses a Distributed Map with S3 iterator to fan out to targets. | Two GHA reusable workflows: `customize-global.yaml` (runs on every stack) and `customize-account.yaml` (runs on stacks that opt in via `vars.customization_name`). Fan-out is a GHA `strategy.matrix` populated from `atmos list instances --format=json --component=customizations/<name>` (`reference/atmos/website/docs/cli/commands/list/list-instances.mdx`). See §3 and §9 item 7 for the 256-job matrix limit. |
| **Shared-account path** (`aft-analysis.md:109-111`) | `shared_account_request` bypass skips Service Catalog. | Stacks for `ct-management`, `log-archive`, `audit` in `stacks/orgs/<org>/core/` omit the `account-provisioning` component entirely. The provision workflow short-circuits when the stack's component list does not include `account-provisioning`. |

### 2.2 Replacing AFT SFN state transitions with Atmos workflow steps

`aft_account_provisioning_framework.asl.json:1-182` has logic that is not purely `terraform apply`: retries with backoff on IAM eventual consistency, a Choice state for the pipeline-creation gate, error catches around the customer customization SFN. The Atmos equivalents:

- `create_role` retry 5x / 60s / backoff 1.5x — replaced by Terraform's native retry-on-propagation for `iam_role`, plus a GHA step `retry: { attempts: 3, delay: 60s }` on the `iam-deployment-roles` component deploy.
- `run_create_pipeline?` Choice — not needed. In the Atmos model the per-account "pipeline" is just a set of stack files plus matrix job runs; the decision of "does a pipeline exist" is replaced by "does a stack file exist", and Git answers that.
- Error-catch around `aft-account-provisioning-customizations` — the GHA job that runs customization components has `continue-on-error: true` with a conditional that emits a failed-customization annotation via `$GITHUB_STEP_SUMMARY` (`reference/atmos/website/docs/ci/ci.mdx`).
- `notify_success` / `notify_failure` — GHA job status checks + a final `workflow_run`-triggered notifier workflow if the team wants Slack/SNS echo.

### 2.3 Where lifecycle becomes simpler

Atmos' imperative workflow model (`reference/atmos/website/docs/cli/configuration/workflows.mdx`) plus GHA `needs:` replaces four of AFT's seven states (`persist_metadata`, `account_metadata_ssm`, and both `notify_*`) with plain job ordering and step summaries — no extra components required.

### 2.4 Where lifecycle becomes harder

Three things:
- **Custom-provisioning extension point.** AFT lets customers extend the provisioning SFN via `aft-account-provisioning-customizations` (single Pass state by default, replaceable). Our equivalent is a named GHA reusable workflow `custom-provisioning-hook.yaml` that is always called but is a no-op by default. See §9 item 5.
- **Eventual consistency between Service Catalog completion and CT guardrail enforcement.** See §9 item 3.
- **Running `account-provisioning` for an *existing* CT account.** AFT's "INSERT for existing CT account" path (`aft-analysis.md:70`) imports into state. Our equivalent is `terraform import` in the `account-provisioning` component, triggered by a `metadata.hooks.import` entry or a one-shot workflow invocation. See §9 item 2.

---

## 3. CodeBuild / CodePipeline → GHA workflows

AFT's five runtime CodeBuild projects and four static + one dynamic CodePipeline (`aft-analysis.md:115-149`) collapse into a small set of GHA workflows.

### 3.1 CodeBuild projects

| AFT CodeBuild project | AFT state key | Replacement |
|---|---|---|
| `ct-aft-account-request` (`aft-analysis.md:119`) | `account-request/terraform.tfstate` | **Not a separate workflow.** There is no `aft-request` DDB table. Stack YAML edits in the PR *are* the request. The step that would have run `terraform apply` against the account-request repo is replaced by `atmos validate stacks` + `atmos describe affected` in the PR workflow. |
| `ct-aft-account-provisioning-customizations` (`aft-analysis.md:121`) | `account-provisioning-customizations/terraform.tfstate` | **Not needed as a pipeline.** The customer-owned customization SFN in the AFT model is a single Pass by default. We replace it with the `custom-provisioning-hook.yaml` reusable workflow described in §2.2. If the team writes Terraform-managed resources into that extension (e.g., a ServiceNow change-record resource), it becomes a normal component under `components/terraform/custom-hooks/` with its own stack. |
| `aft-global-customizations-terraform` (`aft-analysis.md:123`) | `<account>-aft-global-customizations/terraform.tfstate` | GHA reusable workflow **`customize-global.yaml`** calling `atmos terraform deploy customizations/<name> -s <stack>`. `target_admin_role_arn` rendering disappears — Atmos' `auth:` chain sets the provider `assume_role` block natively (`reference/atmos/website/docs/stacks/auth.mdx`). `pre-api-helpers.sh` / `post-api-helpers.sh` are replaced by workflow `run:` steps before/after the deploy. |
| `aft-account-customizations-terraform` (`aft-analysis.md:125`) | `<account>-aft-account-customizations/terraform.tfstate` | GHA reusable workflow **`customize-account.yaml`**. Same shape as `customize-global`. The AFT short-circuit when no customization dir exists (`aft-account-customizations-terraform.yml:1-190`) is replaced by matrix filtering: `atmos list instances --component=customizations/<name>` simply returns nothing for accounts that haven't opted in. |
| `aft-create-pipeline` (`aft-analysis.md:127`) | `<account>-customizations-pipeline/terraform.tfstate` | **Does not exist.** There is no per-account pipeline artifact to materialise. Matrix-jobs-at-dispatch-time is the native GHA replacement; see §9 item 4 for the concurrency consequences. |
| `aft-lambda-layer` build-time project (`aft-analysis.md:129`) | — | Not needed. |

### 3.2 CodePipelines

| AFT pipeline | Replacement |
|---|---|
| `ct-aft-account-request` (`aft-analysis.md:137`) | PR workflow `.github/workflows/pr.yaml` — runs `atmos validate stacks`, `atmos describe affected --format=matrix`, posts plan output. On merge, the `main`-push workflow drives `provision-account`. |
| `ct-aft-account-provisioning-customizations` (`aft-analysis.md:138`) | Same PR workflow covers any change in `components/terraform/custom-hooks/` or its stack config. No dedicated pipeline. |
| **Dynamic `${account_id}-customizations-pipeline`** (`aft-analysis.md:144-148`) | Reusable workflows `customize-global.yaml` + `customize-account.yaml` called from a dispatcher workflow whose matrix is populated from `atmos list instances`. |

### 3.3 Buildspecs → GHA steps

Every AFT buildspec resolves to four concrete GHA steps: (1) `aws-actions/configure-aws-credentials@v4` (OIDC into the central deployment role — replaces `sts assume-role AWSAFTAdmin`), (2) optional `aws sts assume-role` for cross-account (replaces `aft-target` profile — in Atmos this is the provider's `assume_role` and happens inside Terraform, not in the buildspec), (3) `atmos terraform deploy <component> -s <stack> --ci`, (4) summary write to `$GITHUB_STEP_SUMMARY`. The backend-rendering step (`backend.jinja`) disappears entirely: Atmos generates `backend.tf.json` per run (`reference/atmos/examples/quick-start-advanced/atmos.yaml:42`). The provider-rendering step (`aft-providers.jinja`) disappears because the `auth:` chain and `providers:` section render providers natively.

---

## 4. State and queue resources → Atmos stores + Git + GHA

AFT's four DDB tables, one FIFO SQS, two SNS topics, four SFNs, and custom EventBridge bus (`aft-analysis.md:153-200`) map to a mix of Git, Atmos stores, and GHA primitives. Most disappear.

### 4.1 DynamoDB

| AFT table | Purpose | Replacement |
|---|---|---|
| `aft-request-metadata` (`aft-analysis.md:161`) | Materialised account metadata read by SFN + every buildspec. | `atmos describe stacks` computes this on demand (`reference/atmos/website/docs/cli/commands/describe/stacks.mdx`) — no persistent store needed. Where runtime-materialised data is required (notably the vended `account_id`), it lands in SSM via `store-outputs` and is read via `!store`. |
| `aft-request` (`aft-analysis.md:162`) | The request inbox. DDB stream. | Git: `stacks/orgs/<org>/<ou>/<account>/<region>.yaml`. PR merge is the INSERT, PR change is the MODIFY, file deletion is the REMOVE. Streaming is replaced by `atmos describe affected --format=matrix`. |
| `aft-request-audit` (`aft-analysis.md:163`) | Audit log of request transitions. | Git history + GHA run history. `git log stacks/orgs/<org>/<ou>/<account>/` is the same audit trail, signed and immutable. |
| `aft-controltower-events` (`aft-analysis.md:164`) | Persisted CT lifecycle events. | Not reproduced. CT already writes these to CloudTrail; if we need querying, a Config Aggregator or CloudTrail Lake view in the audit account replaces it. See §9 item 8. |
| `aft-backend-<id>` state lock (`aft-analysis.md:166`) | Terraform state lock. | `components/terraform/tfstate-backend/` with `use_lockfile: true` (S3 native locking, no DDB — `reference/atmos/website/docs/stacks/backend.mdx`). |

### 4.2 SQS / SNS / EventBridge

| AFT resource | Purpose | Replacement |
|---|---|---|
| `aft-account-request.fifo` + DLQ (`aft-analysis.md:172`) | Throttle + retry point between DDB-stream handler and Service Catalog. | GHA `concurrency: group: ct-provisioning, cancel-in-progress: false` on the provision workflow. `maxReceiveCount=1` → GHA job-level `retry: attempts: 1`. DLQ semantics → failed workflow runs in GHA run history. |
| `aft-notifications` SNS (`aft-analysis.md:179`) | Success/progress echo. | GHA job summary + optional notifier workflow that republishes to SNS if the team wants downstream systems to keep consuming SNS. |
| `aft-failure-notifications` SNS (`aft-analysis.md:180`) | Failure echo. | Same as above; GHA workflow status checks are the primary signal, SNS is optional. |
| Custom bus `aft-events-from-ct-management` (`aft-analysis.md:197`) | Cross-account CT → aft-mgmt event delivery. | Not required. `account-provisioning`'s Terraform resource call returns on completion with outputs; no async event needed. If later phases need to react to CT events (drift detection, reconciliation), a dedicated bus lives in a separate component but is *not* part of account provisioning. |
| Schedule `aft-lambda-account-request-processor` rate(5m) (`aft-analysis.md:200`) | Drains SQS and calls Service Catalog. | GHA `workflow_dispatch` triggered by the PR merge. No polling. |

### 4.3 SSM parameters (the `/aft/...` config plane)

AFT's ~50 SSM parameters (`aft-analysis.md:53-55`) split cleanly:

- **Static platform config** → `atmos.yaml` (Terraform version, module sources, region defaults, log retention) or catalog defaults under `stacks/catalog/*/defaults.yaml`. Read by every component via `vars:` and `settings:` inheritance.
- **Runtime cross-account data** → SSM via `stores:` in `atmos.yaml`:
  ```yaml
  stores:
    core-ssm:
      type: aws-ssm-parameter-store
      options:
        region: us-east-1
        prefix: /aft/account/
  ```
  Written by `store-outputs` hooks on `after-terraform-apply`; read by `!store core-ssm <component> <key>` in downstream stacks (`reference/atmos/website/docs/stacks/sharing-state/stores.mdx`).
- **The `terraform_token` SecureString** → GHA repository/environment secret injected via `aws-actions/configure-aws-credentials` or `ATMOS_TERRAFORM_TOKEN` env for HCP mode. Not stored in SSM by us.

### 4.4 Step Functions

| AFT SFN | Replacement |
|---|---|
| `aft-account-provisioning-framework` | Atmos workflow file `stacks/workflows/provision-account.yaml` invoked from a GHA workflow. |
| `aft-account-provisioning-customizations` | GHA reusable workflow `custom-provisioning-hook.yaml` (no-op default). |
| `aft-invoke-customizations` | GHA dispatcher workflow using `atmos list instances` → matrix → `customize-global.yaml`/`customize-account.yaml` reusable workflows. |
| `aft-feature-options` | Three inline workflow steps in `provision-account.yaml`, gated by stack vars. No separate orchestrator. |

---

## 5. IAM → Atmos `auth:` chain + GHA OIDC

AFT's three-role chain `AWSAFTAdmin → AWSAFTExecution / AWSAFTService` with pinned session `AWSAFT-Session` (`aft-analysis.md:204-247`) remains a three-hop logical chain, but the identities and trust policies change:

```
GHA OIDC principal (token.actions.githubusercontent.com)
  └─ sts:AssumeRoleWithWebIdentity → AtmosCentralDeploymentRole (in aft-mgmt / shared-services account)
       └─ sts:AssumeRole → AtmosDeploymentRole  (in any target account)
```

### 5.1 Chain mapping

| AFT | Atmos + GHA |
|---|---|
| Caller: Terraform operator or CodeBuild service role in aft-mgmt | Caller: GHA workflow running with `permissions: id-token: write`. |
| `AWSAFTAdmin` in aft-management (`aft-analysis.md:219-224`) | `AtmosCentralDeploymentRole` in a shared-services account (OIDC-trusted to this repo's `main` branch and to tag refs). Provisioned by `components/terraform/github-oidc-provider/` + `components/terraform/iam-deployment-roles/central`. |
| `AWSAFTExecution` in every target (`aft-analysis.md:226-235`) | `AtmosDeploymentRole` in every target account. Provisioned by `components/terraform/iam-deployment-roles/target` deployed in each target account's stack. Trust policy allows `AtmosCentralDeploymentRole`'s assumed-role ARN. |
| `AWSAFTService` (`aft-analysis.md:237-239`) | Not reproduced. The separate "service" identity existed only for Service Catalog portfolio share; Control Tower already has that covered. If a second identity is needed for Account Factory's provisioning principal, it is created as `AtmosProvisioningRole` in aft-mgmt and called only by the `account-provisioning` component. |
| Pinned session name `AWSAFT-Session` (`aft-analysis.md:217`) | Pinned session name `atmos-<stack>-<run_id>` (set via `role-session-name` on `configure-aws-credentials`). Trust policies can reference either the role ARN or the assumed-role ARN pattern; we will use the role ARN form to avoid AFT's brittleness. |

### 5.2 Atmos `auth:` blocks

`reference/atmos/website/docs/stacks/auth.mdx` lets us express the chain declaratively in `atmos.yaml`:

```yaml
auth:
  providers:
    gha-oidc:
      kind: aws/ambient
    central:
      kind: aws/assume-role
      role_arn: arn:aws:iam::${SHARED_SERVICES_ACCOUNT_ID}:role/AtmosCentralDeploymentRole
      chain_from: gha-oidc
    target:
      kind: aws/assume-role
      role_arn: arn:aws:iam::{{ .vars.account_id }}:role/AtmosDeploymentRole
      chain_from: central
  identities:
    default:
      provider: target
```

This gives every component, in every stack, a resolved cross-account identity with no `aft-providers.jinja` rendering step and no `~/.aws/credentials` profile juggling. Vended accounts pick up `vars.account_id` from `!store core-ssm account-provisioning account_id`.

### 5.3 Per-Lambda roles

AFT's per-Lambda execution roles (`aft-analysis.md:241-243`) disappear because the Lambdas disappear. Atmos runs Terraform locally in GHA; no execution roles to define.

### 5.4 Bootstrap identities — two distinct problems

The deploy-time chain above presumes *two* sets of roles already exist: (a) `AtmosCentralDeploymentRole` + the OIDC provider in aft-mgmt; (b) `AtmosDeploymentRole` in every target account whose stack is being deployed. Both must be bootstrapped from outside the normal chain. They are two separate problems and need two separate answers.

**Bootstrap problem A — central role (one-time).** Before any GHA workflow can authenticate, `AtmosCentralDeploymentRole` and the GitHub OIDC provider must already exist in aft-mgmt. The `bootstrap.yaml` workflow (see `gha-design.md` §5.8) handles first-run with a short-lived privileged IAM user (`AtmosBootstrapUser`) or an operator with `AdministratorAccess` in aft-mgmt, running `atmos terraform apply github-oidc-provider iam-deployment-roles/central tfstate-backend -s aft-mgmt-<region>`. Documented as a one-time operation; the access key is deleted afterwards (task #10).

**Bootstrap problem B — target role per newly vended account.** The `provision-account.yaml` workflow (see `gha-design.md` §5.3) deploys `tfstate-backend` and `iam-deployment-roles/target` into the *newly vended* account as jobs 3 and 4. Those two jobs run **before** `AtmosDeploymentRole` exists in the target, so the target-account link of the chain in §5.2 is not usable yet. The chain for those two jobs is:

```
GHA OIDC principal
  └─ AtmosCentralDeploymentRole (aft-mgmt)
       └─ AWSControlTowerExecution (in newly vended account)
```

`AWSControlTowerExecution` is the role Control Tower stamps into every CT-vended account as part of Account Factory — the same role AFT uses in its `providers.tf` aliases and the *only* runtime use of `AWSControlTowerExecution` in AFT (`aft-analysis.md:15`, §5.1). It is trusted by the CT management account's Organizations root, so `AtmosCentralDeploymentRole` needs `sts:AssumeRole` on `arn:aws:iam::*:role/AWSControlTowerExecution` as a permission in its attached policy. For non-CT-vended accounts — `ct-management`, `audit`, `log-archive` — the equivalent fallback is `OrganizationAccountAccessRole`; bootstrap stamping of `AtmosDeploymentRole` into those four CT-managed accounts is a separate one-time step in `bootstrap.yaml` using the same chain (see task #10).

**Atmos `auth:` provider alias.** We express the bootstrap chain as a *second* identity in `atmos.yaml`, used only by the two bootstrap components:

```yaml
auth:
  providers:
    gha-oidc: { kind: aws/ambient }
    central:
      kind: aws/assume-role
      role_arn: arn:aws:iam::${AFT_MGMT_ACCOUNT_ID}:role/AtmosCentralDeploymentRole
      chain_from: gha-oidc
    target:
      kind: aws/assume-role
      role_arn: arn:aws:iam::{{ .vars.account_id }}:role/AtmosDeploymentRole
      chain_from: central
    target-bootstrap:
      kind: aws/assume-role
      role_arn: arn:aws:iam::{{ .vars.account_id }}:role/AWSControlTowerExecution
      chain_from: central
  identities:
    default: { provider: target }
    bootstrap: { provider: target-bootstrap }
```

The two components that run before `AtmosDeploymentRole` exists pin the bootstrap identity in their stack catalog defaults:

```yaml
# stacks/catalog/tfstate-backend/defaults.yaml
components:
  terraform:
    tfstate-backend:
      auth:
        identities:
          bootstrap: { default: true }

# stacks/catalog/iam-deployment-roles/target/defaults.yaml
components:
  terraform:
    iam-deployment-roles/target:
      auth:
        identities:
          bootstrap: { default: true }
```

Every other component defaults to `identities.default` (the normal `target` chain). After job 4 of `provision-account.yaml` stamps `AtmosDeploymentRole`, job 5 onwards runs under that role without any workflow-level switch: the provider alias is picked from stack catalog, so jobs 5–12 naturally use the `target` identity.

**Workflow-level handoff.** `gha-design.md` §6 defines a dedicated `_bootstrap-target.yaml` reusable workflow that is called only by `provision-account.yaml` jobs 3 and 4. It is functionally identical to `_atmos-apply.yaml` but sets `ATMOS_AUTH_IDENTITY=bootstrap` so Atmos picks the `target-bootstrap` provider instead of `target`. All other callers (jobs 5–12, `customize-fleet.yaml`, `destroy-account.yaml`) keep using `_atmos-apply.yaml` with the default `target` identity.

This keeps the `AWSControlTowerExecution` blast radius tiny: one provider alias, two components, two jobs per new account, no long-running credentials. If Control Tower ever renames the role or stops stamping it automatically, the blast radius is two stack-catalog defaults and one provider alias in `atmos.yaml`.

---

## 6. Customer repositories → Atmos stack layout + customization components

AFT's four customer repos (`aft-analysis.md:251-293`) collapse into this repo. No Jinja, no separate repos.

| AFT repo | Replacement in this repo |
|---|---|
| `aft-account-request` (`aft-analysis.md:255-261`) | `stacks/orgs/<org>/<ou>/<account>/<region>.yaml` stack files. Each stack carries `vars.control_tower_parameters` (AccountEmail, AccountName, ManagedOrganizationalUnit, SSOUser*), `vars.account_tags`, and `vars.customization_name`. The `aws_dynamodb_table_item` writes disappear entirely; the `account-provisioning` component reads these vars directly and calls Service Catalog. |
| `aft-account-provisioning-customizations` (`aft-analysis.md:263-268`) | `custom-provisioning-hook.yaml` reusable workflow + optional `components/terraform/custom-hooks/` for Terraform-managed resources. The single-Pass-state default becomes a workflow that does nothing unless the team defines steps. |
| `aft-global-customizations` (`aft-analysis.md:270-275`) | `components/terraform/customizations/global/` — applied to every stack via an import in `stacks/catalog/customizations/global.yaml`. `pre-api-helpers.sh` / `post-api-helpers.sh` → pre/post steps in the GHA `customize-global.yaml` workflow. |
| `aft-account-customizations` (`aft-analysis.md:277-282`) | `components/terraform/customizations/<name>/` + stack-level opt-in via `vars.customization_name`. Only stacks that set the var get the component; `atmos list instances --component=customizations/<name>` enumerates them. |

### 6.1 The Jinja layer is gone

`backend.jinja` and `aft-providers.jinja` (`aft-analysis.md:286-292`) are the single biggest concrete simplification in this mapping:

- `backend.jinja` → `components.terraform.backend_type` + `backend:` block in the stack; Atmos writes `backend.tf.json` per run.
- `aft-providers.jinja` with rendered `role_arn` → `auth:` chain in `atmos.yaml` + per-stack `providers:` override where needed. Atmos resolves `assume_role` natively.

There is no runtime string interpolation of a role ARN into an HCL file; the chain is a first-class config construct.

### 6.2 Named profile chain

AFT buildspecs juggle three AWS profiles `aft-management-admin`, `aft-target`, `aft-management` inside a single container (`aft-analysis.md:293`). In Atmos, those three contexts map to:

- `aft-management-admin` → Atmos `auth.identities.default` resolved for a stack whose account = aft-mgmt.
- `aft-target` → the same identity resolved for a stack whose `vars.account_id` = the vended account.
- `aft-management` → only used by AFT for state backend writes; in our model state writes also go through the resolved `auth` chain, so there's no third profile.

---

## 7. Terraform state backends → Atmos per-stack backend

AFT runs one central backend in aft-mgmt with keys per customer repo (`aft-analysis.md:297-326`). Our model runs one backend per account with one key per component — a superset, not a replacement.

### 7.1 Backend topology

| AFT | Atmos |
|---|---|
| One bucket `aft-backend-<id>-primary-region` + optional secondary (`aft-analysis.md:303-304`) | `components/terraform/tfstate-backend/` deployed into every account that holds state (typically each managed account). Per-region CMK. Optional secondary bucket is **deferred** (see `atmos-model.md` §9.3.4 — single-region, no DR for Phase 1). **Bootstrap carve-out:** the `tfstate-backend` component's own state lives centrally in aft-mgmt at `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>` keyed `bootstrap/<account-id>/tfstate-backend/terraform.tfstate`, to break the chicken-and-egg. See `atmos-model.md` §9.3. |
| DDB lock table `aft-backend-<id>` (`aft-analysis.md:305`) | **None.** `use_lockfile: true` uses S3's native locking. Matches `atmos-model.md` §9.3. |
| Per-region KMS with rotation, 30-day deletion window (`aft-analysis.md:306`) | Same, provisioned by `tfstate-backend` vars. |
| S3 server access logs bucket (`aft-analysis.md:307`) | Optional; recommended to centralise in the log-archive account via the `s3-log-storage` component. |

### 7.2 Backend modes

AFT switches OSS vs HCP via `var.terraform_distribution` and cannot flip at runtime (`aft-analysis.md:309-313`). Atmos handles both natively via `components.terraform.backend_type` — a stack can select `s3`, `remote` (HCP), or `azurerm`/`gcs` per component. Phase 1 defaults to `s3` across the board. HCP support is a flag flip in `atmos.yaml`, not a re-bootstrap. See `reference/atmos/website/docs/stacks/backend.mdx`.

### 7.3 State-key mapping

AFT keys are flat paths in one bucket (`aft-analysis.md:315-326`). Atmos keys are `stack/<stack-name>/<component-name>/terraform.tfstate` (`reference/atmos/website/docs/stacks/backend.mdx`). The three columns map directly:

| AFT state key | Atmos equivalent |
|---|---|
| `aft-backend/terraform.tfstate` | `stack/aft-mgmt-ue1/tfstate-backend/terraform.tfstate` |
| `account-request/terraform.tfstate` | **None** — no account-request component exists (§3.1). |
| `account-provisioning-customizations/terraform.tfstate` | `stack/aft-mgmt-ue1/custom-hooks/terraform.tfstate` (only if `custom-hooks` is used). |
| `<id>-aft-global-customizations/terraform.tfstate` | `stack/<tenant>-<env>-<stage>/customizations/global/terraform.tfstate` (per target account). |
| `<id>-aft-account-customizations/terraform.tfstate` | `stack/<tenant>-<env>-<stage>/customizations/<name>/terraform.tfstate`. |
| `<id>-customizations-pipeline/terraform.tfstate` | **None** — no per-account pipeline Terraform. |

---

## 8. Control Tower coexistence matrix

This section is the enforcement surface for the "CT stays" rule. Every component we vendor or write must honour it. The row order is by AWS service, not by AFT section.

| Domain | Owned by Control Tower | Owned by Atmos | Constraint |
|---|---|---|---|
| AWS Organization | CT | — | **Forbidden components:** `aws-organization`. Atmos must not declare the Organization. |
| OUs | CT | — | **Forbidden components:** `aws-organizational-unit`. OU hierarchy comes from CT Landing Zone config. If a new OU is needed, it is created through the CT console / Landing Zone update, not Terraform. |
| Account provisioning lifecycle | CT | `account-provisioning` (wrapper) | Atmos calls the CT Account Factory portfolio via `aws_servicecatalog_provisioned_product`; it does **not** call `aws_organizations_account` directly. **Forbidden components:** `aws-account` (the Cloudposse wrapper). |
| Baseline SCPs (guardrails) | CT | — | CT-managed guardrails must not be reimplemented. |
| Additional SCPs | — | `aws-scp` | Permitted for SCPs that layer on top of CT guardrails (e.g., region restriction beyond CT's set, deny-specific-service policies). Must target only non-CT-managed OUs or accounts where the added policy does not conflict. |
| Org-level CloudTrail | CT | — | Do not enable a second org-level trail. Per-account trails for specialised logging are allowed but discouraged. |
| Config recorder + IAM role | CT | — | **`aws-config` component** must be configured with `create_recorder: false` and `create_iam_role: false` in every stack. The CT-provisioned recorder and role are reused. A second recorder would cause `AWS::Config::ConfigurationRecorder` duplication errors and break the CT drift reconciliation. |
| Baseline Config rules | CT | `aws-config-rules` (additional packs) | Custom rule packs are layered on top of CT's baseline. |
| GuardDuty | — | `aws-guardduty/{delegated-admin,root-delegation,org-settings}` | Three-phase deployment across three stacks in order: (1) `guardduty/delegated-admin` in management account, (2) `guardduty/root-delegation` that delegates administration to the audit account, (3) `guardduty/org-settings` in the audit account that enables the org-wide detector and auto-enable. Encoded via `settings.depends_on` between the three stacks + workflow step ordering. Any attempt to collapse these into one component or one stack instance will race against GuardDuty's own multi-account state machine. |
| Security Hub | — | `aws-security-hub/{delegated-admin,org-settings}` | Two-phase similar to GuardDuty (delegate to audit, then org-enable). |
| Inspector | — | `aws-inspector/{delegated-admin,org-settings}` | Two-phase similar to Security Hub. |
| Identity Center (SSO) | CT (bootstrap) | `iam-identity-center` (permission sets, assignments) | CT creates the Identity Center instance; Atmos manages permission sets and account assignments. Must not try to (re)create the instance itself. |
| Account baselines (password policy, EBS encryption) | — | `aws-account-settings` | Safe to own fully. |
| Budgets | — | `aws-budget` | Safe to own fully. |
| Logging / audit S3 | CT (baseline buckets) | `s3-log-storage` (additional centralised logs) | Do not try to replace CT's Landing Zone logging buckets. |
| GHA OIDC provider | — | `github-oidc-provider` | Safe to own fully. |
| Deployment roles | — | `iam-deployment-roles/{central,target}` | Safe to own fully. **`iam-deployment-roles/central`** (deployed once in atmos-aft mgmt) creates `AtmosCentralDeploymentRole`, `AtmosPlanOnlyRole`, and `AtmosReadAllStateRole` (decrypt-only cross-account reader introduced by task #9, `atmos-model.md §9.3.2`). **`iam-deployment-roles/target`** (deployed in every account Atmos applies against — all five classes: CT-mgmt, AFT-mgmt, audit, log-archive, vended) stamps `AtmosDeploymentRole` + `AtmosDeploymentRole-ReadOnly`. The four CT-managed core placements (which predate Atmos) are stamped by `bootstrap.yaml` §5.8 step 5 via `_bootstrap-target.yaml` with `fallback_role=OrganizationAccountAccessRole`. Vended accounts are stamped by `provision-account.yaml` job 4 via the same reusable with `fallback_role=AWSControlTowerExecution`. Trust policy is identical across all placements except for an `sts:ExternalId` guardrail on the four CT-core variants. Full role matrix (home account, creator, trust, permissions, use) in `gha-design.md §4.6.1`. |

### 8.1 Enforcement

- **`vendor.yaml`** must not list `aws-organization`, `aws-organizational-unit`, or `aws-account`. A pre-commit hook or an OPA policy under `stacks/schemas/opa/` (`reference/atmos/examples/quick-start-advanced/atmos.yaml:183-192`) enforces this.
- **`aws-config` stack defaults** in `stacks/catalog/aws-config/defaults.yaml` set `create_recorder: false` and `create_iam_role: false` at the catalog level so no downstream stack can forget.
- **GuardDuty sequencing** is encoded both in `settings.depends_on` between the three stack instances and in the ordering of `stacks/workflows/provision-account.yaml`.

---

## 9. Does not map cleanly — explicit flags for task #3 and task #4

These are the AFT concepts whose Atmos/GHA equivalent is either lossy, awkward, or genuinely new work.

1. **Request routing rules.** AFT's `AccountRequestRecordHandler.process_request()` (`aft-analysis.md:67-73`) has six code-level branches (INSERT, INSERT-existing-CT, MODIFY with CT change, MODIFY without, REMOVE, shared-account). The PR-describe-affected flow covers the first four cleanly but: (a) **"INSERT for an existing CT account" (import path)** requires a separate one-shot workflow `import-account.yaml` since Terraform needs explicit `terraform import` calls — it is not triggered by a stack-file add; and (b) **REMOVE semantics** (`aft-cleanup-resources` Lambda) are destructive and GHA-on-deletion triggers are less reliable than DDB streams on `REMOVE`. The GHA workflow needs to handle tombstone-style stack-file markers (`metadata.deleted: true`) rather than relying on file deletion detection.

2. **`account-provisioning` import path.** Because the Cloudposse `aws-account` module is forbidden and our component wraps Service Catalog directly, importing a pre-existing provisioned-product (any account Control Tower already vended before we adopted this repo) requires a `terraform import aws_servicecatalog_provisioned_product.this <product_id>` step. This is not a one-liner — the product ID has to be looked up from Service Catalog API. Proposed approach: a bootstrap script `scripts/import-existing-accounts.sh` that lists Service Catalog products in aft-mgmt and generates the `terraform import` commands. Flagged for AWS architect review.

3. **Service Catalog completion ≠ CT guardrail enforcement.** AFT's Phase C event crossing (`aft-analysis.md:80-87`) waits for the `CreateManagedAccount` event on ct-mgmt's default bus; that event fires *after* CT finishes applying guardrails, not when Service Catalog returns. `aws_servicecatalog_provisioned_product` returns on Service Catalog completion, which is earlier. For strict correctness the provision workflow should poll Control Tower or EventBridge after the `account-provisioning` step. Options to decide in task #3:
   - (a) Poll `organizations:DescribeAccount` + a `time_sleep` until account is `ACTIVE` and in the target OU.
   - (b) Post a GHA re-entrant workflow triggered by an EventBridge → SNS → API Gateway webhook (heavy).
   - (c) Accept the eventual-consistency risk and retry the subsequent baseline components with backoff (simplest; matches AFT's `create_role` retry pattern).
   Recommend (c) for Phase 1 with explicit call-out in runbook.

4. **Per-account matrix concurrency limits.** GHA `strategy.matrix` caps at 256 jobs per workflow run. AFT handles this with a Distributed Map + S3 iterator (`aft-analysis.md:107`). If we ever need to fan out customizations across 256+ accounts in one workflow, we need either (a) chunked dispatch via multiple `workflow_call`s, (b) self-hosted runners with a custom fan-out action, or (c) `atmos describe affected` applied cumulatively so each PR only touches a subset. For Phase 1 / target scale (< 100 accounts) this is not a blocker, but task #3 should document the chunking strategy for later.

5. **Customer-owned provisioning extension point.** AFT's customer-owned `aft-account-provisioning-customizations` SFN (`aft-analysis.md:189`, `aft-analysis.md:266-268`) is a first-class extension seam — customers wire approvals, ServiceNow tickets, compliance gates there with zero AFT code changes. Our equivalent `custom-provisioning-hook.yaml` reusable workflow is nominally equivalent, but GHA's permission model for cross-repo `workflow_call` differs: if customer extensions live outside this repo, we need either a published reusable workflow + `permissions:` contract or a subdirectory in this repo treated as customer-owned. Flagged for task #3 — proposed: subdirectory `.github/workflows/custom/` reserved for operator-provided hooks, with a lint rule to prevent non-hook workflows from living there.

6. **DDB stream as single event source → Git as single event source.** AFT's `aft-request` DDB stream (`aft-analysis.md:334`) is a single point of failure *and* a single point of audit. Git gives us the same single-source guarantee for account *requests*, but status transitions (provisioning started / CT event received / customization pipeline finished) that AFT writes back into `aft-request-metadata` now have no persistent home by default. Proposed: add an explicit `account-status` SSM namespace written by the provision workflow (`/aft/account/<name>/status`) with states `provisioning | baseline-deployed | customized | drift | failed`. Not a blocker; flagged so task #3 defines the status schema.

7. **Drift detection.** AFT has no built-in drift detection either — customers bolt on `terraform plan` on a schedule. Atmos has `cloudposse/github-action-atmos-terraform-drift-detection` (cited in `atmos-model.md` §12) which covers this. Not a gap vs AFT, but worth calling out that Phase 1 should ship drift detection that AFT's reference stack does not have — this is a positive delta.

8. **Per-account CT event history.** `aft-controltower-events` DDB table (`aft-analysis.md:164`) is a useful audit artifact that our model drops. If compliance requires a queryable CT event history, task #4 may push for a CloudTrail Lake view in the audit account or a dedicated `ct-event-logger` component. Flagged as optional.

9. **Lambda-layer build.** Not a gap — we don't have Lambdas — but noted because any future custom Atmos hooks that need Python code would need a comparable build step. Phase 1 avoids this entirely.

10. **`terraform_token` secret storage.** AFT puts it in SSM SecureString (`aft-analysis.md:55`). We put it in GHA encrypted secrets. Operationally equivalent, but the rotation story differs: rotating a GHA secret requires repo admin; rotating a SecureString requires `ssm:PutParameter` permissions. Document in runbook.

11. **Forbidden components enforcement.** §8.1 proposes OPA policies + pre-commit, but Phase 1 must actually ship these before the first PR that adds an `aws-config` stack, otherwise the `create_recorder: false` default is advisory only. Task #3 should include workflow steps that fail the PR check if `aws-organization`, `aws-organizational-unit`, or `aws-account` appears in `vendor.yaml` or any component reference.

---

## 10. Summary deltas vs AFT

Net structural changes, from largest to smallest simplification:

1. **No Lambdas, no SFNs, no DDB, no SQS, no custom EventBridge.** AFT's 10+ Lambdas, 4 SFNs, 4 DDB tables, 1 FIFO SQS, 2 SNS topics, and 1 custom bus collapse into Git, GHA workflows, Atmos stores, and one custom Terraform component (`account-provisioning`). Operational surface shrinks dramatically.
2. **No Jinja.** Backend and provider rendering become first-class Atmos config.
3. **No CodeBuild, no CodePipeline.** GHA replaces both, with the per-account dynamic pipeline replaced by matrix dispatch.
4. **Three-role chain kept, names changed.** `AtmosCentralDeploymentRole` + `AtmosDeploymentRole` replace `AWSAFTAdmin` + `AWSAFTExecution`; `AWSAFTService` collapses.
5. **Customer repos collapse into one repo.** `aft-account-request`, `aft-account-provisioning-customizations`, `aft-global-customizations`, `aft-account-customizations` all become directories in this repo.
6. **Baseline security moves into the factory.** AFT defers baseline to customer customizations; we ship `aws-config`, `aws-guardduty/*`, `aws-security-hub`, `aws-inspector`, `iam-identity-center` as first-party components with CT-coexistence flags baked in.
7. **One new custom component.** `account-provisioning` wrapping Service Catalog — the single irreducible piece of this replacement.

Net new risks vs AFT, all covered in §9:
- Loss of `aft-request-metadata` persistent status → SSM namespace under `/aft/account/<name>/status`.
- Loss of DDB-stream-driven REMOVE semantics → tombstone markers in stack YAML.
- Service Catalog completion vs CT guardrail enforcement timing → accept eventual consistency + retry.
- GHA matrix 256-job ceiling → chunked dispatch at scale.
- Cross-repo extension seam → reserved subdirectory + `workflow_call` contract.

This mapping is the input to task #3 (GHA workflow topology) and task #4 (AWS architect review). Every "does not map cleanly" item in §9 is a design decision those tasks must close.

---

## 11. Reference: source files cited

From `reference/aft/` (via `aft-analysis.md` line refs):
- `main.tf`, `locals.tf`, `providers.tf`
- `modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json`
- `modules/aft-account-request-framework/{ddb,sqs,sns,eventbridge,lambda,iam}.tf`
- `modules/aft-backend/main.tf`
- `modules/aft-code-repositories/{codebuild,codepipeline,codecommit,locals}.tf` and `buildspecs/*.yml`
- `modules/aft-customizations/{codebuild,states/invoke_customizations.asl.json,iam}.tf` and `buildspecs/*.yml`
- `modules/aft-feature-options/states/aft_features.asl.json`
- `modules/aft-iam-roles/iam.tf`, `admin-role/main.tf`, `service-role/main.tf`, `iam/*.tpl`
- `modules/aft-ssm-parameters/ssm.tf`
- `sources/aft-customizations-repos/aft-account-request/terraform/modules/aft-account-request/ddb.tf`
- `sources/aft-customizations-repos/aft-account-provisioning-customizations/terraform/states/customizations.asl.json`
- `sources/aft-customizations-common/templates/customizations_pipeline/codepipeline.tf`
- `sources/aft-lambda-layer/aft_common/{account_request_record_handler,customizations,shared_account,notifications}.py`
- `src/aft_lambda/aft_account_request_framework/{aft_account_request_action_trigger,aft_account_request_processor,aft_invoke_aft_account_provisioning_framework}.py`

From `reference/atmos/`:
- `reference/atmos/examples/quick-start-advanced/atmos.yaml`
- `reference/atmos/website/docs/stacks/{stacks,imports,name,backend,auth,hooks,overrides}.mdx`
- `reference/atmos/website/docs/stacks/components/metadata.mdx`
- `reference/atmos/website/docs/stacks/sharing-state/stores.mdx`
- `reference/atmos/website/docs/functions/yaml/{store,terraform.output,terraform.state}.mdx`
- `reference/atmos/website/docs/ci/ci.mdx`
- `reference/atmos/website/docs/cli/commands/describe/{stacks,affected}.mdx`
- `reference/atmos/website/docs/cli/commands/list/list-instances.mdx`
- `reference/atmos/website/docs/cli/commands/workflow.mdx`
- `reference/atmos/website/docs/cli/commands/terraform/{deploy,apply,plan}.mdx`
- `reference/atmos/website/docs/cli/configuration/{workflows,vendor}.mdx`
- `reference/atmos/website/docs/integrations/github-actions/affected-stacks.mdx`
- `reference/atmos/website/docs/design-patterns/stack-organization/organizational-hierarchy-configuration.mdx`
- `reference/atmos/pkg/schema/schema.go`

From this repo:
- `docs/architecture/atmos-model.md` (sections §11 and §12 for the coexistence layout and gaps).
- `docs/architecture/aft-analysis.md` (all seven sections).
