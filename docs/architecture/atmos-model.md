# Atmos Model for a Multi-Account AWS Factory

This document is the ground-truth description of the Cloudposse Atmos configuration and execution model as it applies to building an AWS multi-account "account factory" — an AFT replacement. It is aimed at engineers who have never used Atmos. Every non-obvious claim cites a file under `reference/atmos/`.

Scope: the parts of Atmos that matter for provisioning and operating many AWS accounts from YAML configuration driven by GitHub Actions. Atmos features that are out of scope for this project (Helmfile, Packer, Ansible, Spacelift/Atlantis, the TUI) are mentioned only where a reader needs to understand the shape of the system.

---

## 1. The mental model

Atmos is, at its core, a YAML configuration engine plus a thin Terraform wrapper. You write two things:

1. **Components** — Terraform root modules under `components/terraform/<name>/`. These are implementation: `.tf` files, resources, inputs, outputs. They know nothing about environments, accounts, or regions.
2. **Stacks** — YAML files under `stacks/` that configure which component instances exist, in which account and region, with which variables and which backend.

A *stack* in Atmos is a logical environment — a named slice of your infrastructure such as `plat-ue2-prod`. A *component instance* is one component configured inside one stack. Atmos turns `(component, stack)` into a concrete Terraform run: resolved variables, resolved backend, resolved workspace, resolved AWS identity.

`reference/atmos/website/docs/components/components-overview.mdx:17-33` makes the separation explicit: "Components … consist of two parts: Implementation — the infrastructure code itself … and Configuration — the settings that customize how the component is deployed in each environment."

All Atmos behavior flows from one data-transformation pipeline, described in the top-level `reference/atmos/CLAUDE.md` as "Load atmos.yaml → process imports/inheritance → apply overrides → render templates → generate config." Everything below is an elaboration of that one sentence.

---

## 2. `atmos.yaml` — the project root

`atmos.yaml` at the repo root tells Atmos where everything lives. Loading precedence is `system dir → ~/.atmos → current directory → env vars → CLI flags` (`reference/atmos/examples/quick-start-advanced/atmos.yaml:1-9`). For our factory we will commit one `atmos.yaml` at the repo root; machine-local overrides are not wanted.

Key sections relevant to us (all from `reference/atmos/examples/quick-start-advanced/atmos.yaml`):

- `base_path: "."` — root of the Atmos project (line 18).
- `components.terraform.base_path: "components/terraform"` — where root modules live (line 34). `auto_generate_backend_file: true` (line 42) tells Atmos to write `backend.tf.json` next to the module before each run.
- `stacks.base_path: "stacks"` (line 61), `stacks.included_paths: ["orgs/**/*"]` (line 64), `stacks.excluded_paths: ["**/_defaults.yaml"]` (line 67) — defines which YAML files are real top-level stacks vs import fragments.
- `stacks.name_pattern: "{tenant}-{environment}-{stage}"` (line 69) — the logical stack identifier used on the `-s` flag. For AFT, this is how a caller says "this account, this region." `name_template` (Go template over `.vars`) is the more flexible modern form (`reference/atmos/website/docs/stacks/name.mdx:40-45`).
- `workflows.base_path: "stacks/workflows"` (line 74) — workflow definitions (see §7).
- `schemas.jsonschema` and `schemas.opa` (lines 183-192) — validation rules applied to component configs.
- `templates.settings.enabled: true` with Sprig and Gomplate (lines 210-221) — turns on Go-template processing inside stack YAML.
- `settings.list_merge_strategy` (lines 223-234) — controls how lists in stack manifests merge across imports (`replace` default; `append` and `merge` available).

The file also hosts top-level sections we will rely on heavily: `auth:` (identities and providers, §9), `stores:` (external KV backends, §8), and `commands:` (custom CLI sub-commands, §10).

---

## 3. Stacks: YAML, imports, inheritance

### 3.1 Stack manifest structure

A stack manifest is one YAML file. `reference/atmos/website/docs/stacks/stacks.mdx:19-34` enumerates the supported top-level keys. The ones we care about:

| Section | Purpose | Scope |
|---------|---------|-------|
| `import` | Pull in other YAML files (deep-merged in order) | top-level |
| `vars` | Variables passed to every component | global, per-component-type, per-component |
| `env` | Environment variables for `terraform` process | global, per-component-type, per-component |
| `settings` | Atmos/integration metadata (not passed to Terraform) | same |
| `terraform` | Type-level defaults for all Terraform components | top-level |
| `components.terraform.<name>` | A specific component instance | component |
| `components.terraform.<name>.metadata` | How Atmos treats this instance | component only |
| `components.terraform.<name>.vars` | Terraform input variables | component |
| `components.terraform.<name>.backend` / `backend_type` | State storage | component-type or component |
| `components.terraform.<name>.providers` | Provider config generated into the module | component-type or component |
| `components.terraform.<name>.auth` | Which auth identity to use | component |
| `components.terraform.<name>.hooks` | Post-apply lifecycle hooks | global/type/component |
| `overrides` | Force values that beat component-level settings | top-level |

Inheritance is **entirely explicit**: there is no implicit "apply parent directory defaults." Everything comes through `import` (`reference/atmos/website/docs/stacks/imports.mdx:25-34`).

### 3.2 Imports

`import:` is a list of paths, each resolved relative to `stacks.base_path` by default, or relative to the current file when prefixed with `./` or `../` (`reference/atmos/website/docs/stacks/imports.mdx:49-67`). Each listed import is deep-merged on top of what came before — later entries win on scalar conflicts; maps merge; lists use the configured list strategy.

Imports can be:

- **Local paths** — `orgs/acme/_defaults`, `catalog/vpc/defaults`. `.yaml` is auto-appended. If both `foo.yaml` and `foo.yaml.tmpl` exist, Atmos prefers the template (`reference/atmos/website/docs/stacks/imports.mdx:38-47`).
- **Remote paths** — go-getter URLs: `git::…?ref=v1.0.0`, `github.com/org/repo//path?ref=…`, `s3::…`, `gcs::…`, `https://…`, `file://…` (`reference/atmos/website/docs/stacks/imports.mdx:72-138`).
- **Templated imports** — `path:` with a `context:` map parameterizes an imported `.yaml.tmpl` file. Context passes down through nested imports; child context overrides parent on conflict (`reference/atmos/website/docs/stacks/imports.mdx:192-465`).

Templated imports are the mechanism that makes a single "account blueprint" template usable to materialize many accounts by parameter. For the factory, this is how we can get from "account request YAML" to "stack config for that account" without writing one file per account.

### 3.3 The `_defaults.yaml` convention

`_defaults.yaml` files at each directory level hold shared values for that level (`reference/atmos/website/docs/design-patterns/stack-organization/organizational-hierarchy-configuration.mdx:57-67`). The underscore prefix is two things: it sorts to the top of listings, and it matches the `excluded_paths: ["**/_defaults.yaml"]` rule so these files are not themselves treated as top-level stacks. They are plain imports — they do nothing until imported explicitly by a child.

The pattern: each level imports the level above, so a leaf file imports one `_defaults.yaml` and gets the entire chain. From the quick-start-advanced example:

- `stacks/orgs/acme/_defaults.yaml` sets `vars.namespace: acme` and organization-wide Terraform `tags` (`reference/atmos/examples/quick-start-advanced/stacks/orgs/acme/_defaults.yaml:1-30`).
- `stacks/orgs/acme/plat/_defaults.yaml` imports the org defaults and sets `vars.tenant: plat` (lines 1-3).
- `stacks/orgs/acme/plat/prod/_defaults.yaml` imports the tenant defaults and sets `vars.stage: prod` (lines 1-3).
- `stacks/orgs/acme/plat/prod/us-east-2.yaml` imports the prod defaults, the region mixin, and the component catalog entries that should exist in that stack (lines 1-6).

The result after resolution is a single deep-merged document with `namespace: acme`, `tenant: plat`, `stage: prod`, region set from the mixin, and all components declared.

### 3.4 Component inheritance

Independent of file imports, a component instance can inherit from another component instance via `metadata.inherits` (`reference/atmos/website/docs/stacks/components/metadata.mdx:76-98`). This is how we get "abstract templates" for components: declare `metadata.type: abstract` on a base, mark it undeployable, and have concrete components list it under `inherits:`. Atmos processes `inherits` in order; later items and the component's own values win (line 98). Multi-level chains work but `≤3 levels` is the stated guideline.

`metadata.component:` points the instance at a Terraform root module directory. Two instances can share one module by pointing `metadata.component:` at the same directory with different `vars`. `metadata.name:` fixes the backend `workspace_key_prefix` so that versioned folders (`vpc/v2`) do not relocate state when we upgrade (`reference/atmos/website/docs/stacks/components/metadata.mdx:56-75`). This matters for us because the factory will need to roll component versions forward without re-migrating state for hundreds of accounts.

`metadata.enabled: false` disables the instance (`reference/atmos/website/docs/stacks/components/metadata.mdx:120-138`). `metadata.locked: true` refuses changes (lines 140-155). `metadata.terraform_workspace` or `metadata.terraform_workspace_pattern` override the computed workspace name (lines 157-195).

### 3.5 Stack names

Stack name resolution order (`reference/atmos/website/docs/stacks/name.mdx:74-84`): explicit `name:` in the file → `name_template` in `atmos.yaml` → `name_pattern` → basename of the file. `name_template` is a Go template over `vars` and wins for consistent hierarchies. `name` is the escape hatch for legacy or mismatched cases.

For the factory we will use `name_template: "{{ .vars.tenant }}-{{ .vars.environment }}-{{ .vars.stage }}"` (or similar with organization). Every command referencing a stack uses `-s <stack-name>`.

---

## 4. Components

### 4.1 Terraform components

A Terraform component is a *root module* — its own `main.tf`/`variables.tf`/`outputs.tf` under `components/terraform/<name>/`. It is initialized and run in place: Atmos writes `backend.tf.json`, a generated `.tfvars`, and optionally a provider override, then calls `terraform init`, `terraform workspace select`, and the requested subcommand in that directory (`reference/atmos/website/docs/functions/yaml/terraform.output.mdx:62-89` describes the execution sequence).

Key Atmos-generated files per run:

- `backend.tf.json` — from the stack's `backend_type` + `backend` sections (`reference/atmos/website/docs/stacks/backend.mdx:22-31`). Should be gitignored.
- `<component>.terraform.tfvars.json` — the resolved `vars` for that component.
- `providers_override.tf.json` — if `providers:` was set in the stack (`reference/atmos/website/docs/stacks/providers.mdx`).

The workspace name is computed from stack name + component (or from `metadata.terraform_workspace_pattern`). Workspaces give state isolation per `(component, stack)` when backends are shared.

### 4.2 Helmfile / Packer / Ansible

Out of scope for AFT-replacement phase 1 but present in the model: same `components.<type>.<name>` pattern under `components/helmfile/`, `components/packer/`, `components/ansible/` (`reference/atmos/website/docs/components/components-overview.mdx:106-135`). Flagging in case we later need in-account Kubernetes or AMI bakes driven by the same config engine.

### 4.3 Component catalogs

A *catalog* entry is a YAML file under `stacks/catalog/<component>/…` that declares the default `components.terraform.<name>:` block for a component. Stacks then `import: - catalog/<component>/defaults` to pull it in. The quick-start-advanced example ships catalog entries for `vpc/` and `vpc-flow-logs-bucket/` with per-stage variants (`reference/atmos/examples/quick-start-advanced/stacks/catalog/vpc/`). This is the right seam for our factory: the "account baseline" becomes a catalog of component default manifests, and each account's stack is "import the baselines, override per-account vars."

---

## 5. Vendoring upstream components

Our `components/terraform/` will not be hand-authored modules — we will vendor upstream modules (Cloudposse's `terraform-aws-components`, others) into the repo. Atmos ships a vendor manifest format for this.

`vendor.yaml` (file location from `vendor.base_path` in `atmos.yaml`):

```yaml
apiVersion: atmos/v1
kind: AtmosVendorConfig
spec:
  sources:
    - component: "vpc"
      source: "github.com/cloudposse/terraform-aws-components.git//modules/vpc?ref={{.Version}}"
      version: "1.372.0"
      targets: ["components/terraform/vpc"]
      included_paths: ["**/*.tf"]
      excluded_paths: ["**/providers.tf"]
      tags: ["networking"]
```

From `reference/atmos/examples/quick-start-advanced/vendor.yaml:10-34`. `source` supports go-getter (git/https/s3/gcs/oci/local). `{{.Version}}` interpolates `version:`. `included_paths`/`excluded_paths` let us strip `providers.tf` files that would conflict with Atmos's generated provider override. `tags:` lets `atmos vendor pull --tags networking` pull a subset.

Vendor manifests can also be a directory of files — Atmos processes them lexicographically (`reference/atmos/website/docs/cli/configuration/vendor.mdx:146-164`).

Components can also ship their own `component.yaml` manifest (component-manifest form) — useful when an upstream component publishes its own pinned set of sub-dependencies.

`atmos vendor pull [--component <name>] [--tags …]` is the command. In the factory, this runs once on a cadence (dependabot-style) to refresh the vendored modules; the pulled diff goes through PR review like any other change.

---

## 6. CLI: the commands that matter in CI

Organized by workflow stage:

**Discover**
- `atmos list stacks` — all top-level stacks Atmos sees.
- `atmos list components` — unique component definitions across stacks.
- `atmos list instances [-s <glob>] [--format matrix -o $GITHUB_OUTPUT]` — every `(component, stack)` pair, with glob filter. `--format matrix` emits GitHub Actions matrix output (`reference/atmos/website/docs/cli/commands/list/list-instances.mdx:32-64`).
- `atmos describe stacks [--stack …] [--components …] [--sections …] [--format json]` — full resolved config for stacks.
- `atmos describe component <component> -s <stack>` — resolved config for one instance. Produces the same data Atmos would use when provisioning.
- `atmos describe affected [--base <ref>] [--format matrix -o $GITHUB_OUTPUT]` — Git-diff-aware list of affected `(component, stack)` pairs, plus deletions (`reference/atmos/website/docs/integrations/github-actions/affected-stacks.mdx:31-101`, `reference/atmos/website/docs/cli/commands/describe/describe-affected.mdx:46-118`). With `ci.enabled: true` in `atmos.yaml`, the base ref is auto-resolved from `GITHUB_BASE_REF` / push event payload — no `--base` needed (lines 32-117).

**Plan / apply**
- `atmos terraform init <component> -s <stack>` — usually implicit; `components.terraform.deploy_run_init: true` in `atmos.yaml` has the same effect during deploys.
- `atmos terraform plan <component> -s <stack> [--ci]` — with `--ci`, writes a rich GitHub job summary, outputs (`has_changes`, `has_additions`, `has_destructions`, `plan_summary`) to `$GITHUB_OUTPUT`, and can upload the planfile to a configured store (`reference/atmos/website/docs/ci/ci.mdx:26-107`).
- `atmos terraform apply <component> -s <stack>` — plan + apply.
- `atmos terraform deploy <component> -s <stack>` — plan + apply with stored-planfile verification and drift detection against a prior plan.
- `atmos terraform destroy <component> -s <stack>` — destroy one instance.
- `atmos terraform planfile {upload|download|list|delete|show}` — manage the planfile store (S3 / GitHub Artifacts / local) for multi-stage pipelines.

**Vendor**
- `atmos vendor pull [--component …] [--tags …]` — materialize upstream sources into `components/`.

**Workflows**
- `atmos workflow <name> [--file <file>] [--from-step <step>] [--dry-run]` — see §7.

**Validate**
- `atmos validate stacks` — JSON Schema + OPA validation.
- `atmos validate component <component> -s <stack>` — run OPA/JSON Schema policies tied to a component instance.

CI flag: setting `--ci` on plan/apply/deploy (or `ci.enabled: true` in `atmos.yaml`) enables job summaries to `$GITHUB_STEP_SUMMARY`, live status checks (requires `GITHUB_TOKEN`), and output variables (`reference/atmos/website/docs/ci/ci.mdx:88-121`). Auto-detects when running in GitHub Actions.

---

## 7. Workflows

Workflows are YAML files under `stacks/workflows/` that sequence Atmos and shell commands. A workflow file defines one or more named workflows (`reference/atmos/examples/quick-start-advanced/stacks/workflows/networking.yaml`):

```yaml
name: Networking
description: Atmos workflows for managing VPCs and VPC Flow Logs
workflows:
  plan-all-vpc:
    description: Run terraform plan on all vpc components
    steps:
      - name: "vpc in plat-ue2-dev"
        command: terraform plan vpc -s plat-ue2-dev
      - ...
```

Steps can be `atmos` commands (implicit) or shell commands with `type: shell` (`reference/atmos/website/docs/cli/configuration/workflows.mdx:85-138`). Each step runs in its own subprocess — step-level `env:` does not propagate. `working_directory:` may be set at workflow or step level; `!repo-root` YAML function resolves to the git root.

Each workflow supports `env:` at workflow and step level; env precedence is `system → atmos.yaml global → workflow env → step env → auth identity env` (line 162-171).

Workflows can call other workflows with `command: workflow <name>` and custom commands with `command: <custom-cmd>` (`reference/atmos/website/docs/cli/commands/workflow.mdx:31-55`).

The workflow file's `name:` attribute is metadata; the workflow's `-f <file>` flag refers to the file stem (`stacks/workflows/networking.yaml` → `-f networking`).

For the factory, workflows are the building block we wire into GitHub Actions jobs: one GHA step runs `atmos workflow provision-account -f account-factory --stack <stack>`, and the workflow itself sequences the Terraform components that need to land in order (backend/bootstrap → identity → baseline → customizations).

---

## 8. Cross-component data: stores, hooks, `!terraform.output`

Multi-account factories constantly need outputs from one stack read by another stack: a VPC in the network account writes IDs that an app stack in a workload account needs. Atmos offers three mechanisms, in order of runtime cost:

### 8.1 `!terraform.output` (expensive, zero-config)

`!terraform.output <component> [<stack>] <output-or-yq>` in any stack YAML. Atmos resolves by initializing the referenced component in the referenced stack and running `terraform output` (`reference/atmos/website/docs/functions/yaml/terraform.output.mdx:62-107`). Expensive — `init` + `output` per reference — so the docs recommend `!store` or `!terraform.state` in CI.

### 8.2 `!terraform.state` (cheap)

Reads the raw state file directly rather than invoking Terraform. Requires that the caller has permission to read the state backend. Typically faster than `!terraform.output` by a factor of 10+.

### 8.3 Stores (cheapest, explicit publish)

Configure external KV backends in `atmos.yaml` under `stores:` (`reference/atmos/website/docs/stacks/hooks.mdx:85-113`):

```yaml
stores:
  prod/ssm:
    type: aws-ssm-parameter-store
    options:
      region: us-east-1
```

Supported backend types: `aws-ssm-parameter-store`, `azure-key-vault`, `google-secret-manager`, `redis`, `artifactory`.

Components publish outputs via `hooks.store-outputs`:

```yaml
components:
  terraform:
    vpc:
      hooks:
        store-outputs:
          events: [after-terraform-apply]
          command: store
          name: prod/ssm
          outputs:
            vpc_id: .vpc_id
            private_subnet_ids: .private_subnet_ids
```

Consumers read with `!store <store-name> <component> <key>`:

```yaml
eks:
  vars:
    vpc_id: !store prod/ssm vpc vpc_id
```

Lifecycle events currently supported: `after-terraform-apply` (`reference/atmos/website/docs/stacks/hooks.mdx:74-76`).

For an AFT replacement, the pattern is: baseline components publish their outputs (account ID, VPC IDs, role ARNs, KMS keys) to SSM in the management or audit account; workload components read them back by name, without needing to know which stack originally produced them. This replaces AFT's heavy reliance on DynamoDB/Step Functions to ferry data around.

`!terraform.state` and `!terraform.output` cross-stack reads need the caller to have KMS decrypt + S3 get-object on the source stack's backend. The per-account backend topology (§9.3) means any cross-account YAML-function read from aft-mgmt must go through `AtmosReadAllStateRole`; stores (§8.3) are preferred for hot paths because they avoid cross-account state-bucket round-trips entirely.

---

## 9. Auth and the multi-account AWS org

### 9.1 The auth model

`auth:` in `atmos.yaml` defines `providers` and `identities` (`reference/atmos/website/docs/stacks/auth.mdx:64-170`):

- **Providers** — how Atmos gets credentials. Kinds include `aws/iam-identity-center` (AWS SSO), `aws/ambient` (IRSA / EC2 instance profile / ECS task role — trusts the SDK chain), and cloud-agnostic `ambient`. Azure and GCP kinds exist but are not relevant here.
- **Identities** — concrete AWS principals. Kinds include `aws/permission-set` (via SSO), `aws/assume-role` (via another identity), `aws/ambient`. Each identity has `via:` (the chain), `principal:` (role ARN or permission-set + account), and optional `env:` (extra env vars to set for subprocesses).

Two patterns matter to us:

1. **IRSA + assume-role chain** for GitHub Actions self-hosted runners or an in-cluster operator: `pod-base` (`aws/ambient`) chains to `cross-account-deployer` (`aws/assume-role`, `via.identity: pod-base`, `principal.assume_role: arn:aws:iam::<target>:role/TerraformDeployRole`) (`reference/atmos/website/docs/stacks/auth.mdx:314-332`).
2. **OIDC + assume-role** for hosted GitHub runners: GitHub's OIDC token is exchanged for a role in a hub account via `configure-aws-credentials`, then Atmos's `aws/assume-role` identity hops to the target workload account. The pattern is the same chain; only the base identity differs.

Components pick an identity with:

```yaml
components:
  terraform:
    vpc:
      auth:
        identities:
          prod-admin:
            default: true
```

(`reference/atmos/website/docs/stacks/auth.mdx:54-62`).

`auth.realm:` (or `ATMOS_AUTH_REALM`) isolates cached credentials per project — relevant when one runner hosts more than one Atmos repo (`reference/atmos/website/docs/stacks/auth.mdx:384-444`).

### 9.2 Backend per account

Backend config is a deep-merged section. Organization defaults sit in `stacks/orgs/<org>/_defaults.yaml`; per-account overrides (bucket, key) sit in `stacks/orgs/<org>/<tenant>/<stage>/_defaults.yaml`. A typical layout has one central S3 bucket + DynamoDB/use_lockfile in a dedicated state account, with `role_arn` on the backend configured to the TerraformStateAccess role that every workload account's deployer can assume. The backend key template usually includes `{tenant}-{environment}-{stage}-{component}`.

From `reference/atmos/website/docs/stacks/backend.mdx:52-95`:

```yaml
terraform:
  backend_type: s3
  backend:
    s3:
      bucket: acme-ue1-root-tfstate
      region: us-east-1
      encrypt: true
      use_lockfile: true
```

Atmos regenerates `backend.tf.json` on each run; **do not commit it**.

### 9.3 State backend topology — decided

Resolves [`archive/review.md`](archive/review.md) Blocker 3 (archived Phase 1 review). `§9.2` above is the Atmos-mechanics primer; this subsection is the concrete topology the factory ships. Terms: *account state* = state for every component applied inside a vended/managed account. *Bootstrap state* = the one-per-account `tfstate-backend` component's own state.

**Decision.** Per-account primary backend for everything except `tfstate-backend` itself; **central bootstrap backend** in aft-mgmt for `tfstate-backend`'s state. S3-only, native S3 locking (`use_lockfile: true`, no DDB). Single-region per account; no cross-region replication.

Rationale. Per-account buckets align with the "self-contained account" philosophy adopted elsewhere in the design (per-account IAM, per-account KMS, per-account budgets) and mean a blast radius contained to one account for any state-bucket incident. A fleet-wide central backend would concentrate the risk, and drift-detection already works fine against per-account buckets because each `(component, stack)` plan runs under the target's own assumed role. The central bootstrap bucket exists only to break the chicken-and-egg for `tfstate-backend` itself — it never holds anything else.

#### 9.3.1 Buckets, keys, and addressing

| Purpose | Location | Key shape | Who writes | Who reads |
|---|---|---|---|---|
| **Primary account state** (all components except `tfstate-backend`) | S3 bucket in each target account: `atmos-tfstate-<account-id>-<region>` | `stack/<stack-name>/<component-name>/terraform.tfstate` | `AtmosDeploymentRole` in the target account (assumed via the central → target chain) | Same role for plan/apply; `AtmosReadAllStateRole` in aft-mgmt for drift summary aggregation |
| **Bootstrap state** (the `tfstate-backend` component for every account, including aft-mgmt itself) | Single S3 bucket in aft-mgmt: `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>` | `bootstrap/<account-id>/tfstate-backend/terraform.tfstate` | `AtmosCentralDeploymentRole` in aft-mgmt (never target-account identity) | Same role + `AtmosReadAllStateRole` for aggregation |
| **Bootstrap bucket's *own* state** (the one-off backstop) | Same bootstrap bucket, separate key | `bootstrap/self/terraform.tfstate` | operator during initial bootstrap (access-key identity via `bootstrap.yaml`), `AtmosCentralDeploymentRole` thereafter | Same |

The bootstrap bucket's own state is the single place the stack ever relies on `terraform init -migrate-state` (once, operator-run, §9.3.3). Every other backend is created *before* the workload that uses it, with state stored remotely from the first apply.

Stack YAML for the bootstrap case (`tfstate-backend` component in any target stack) overrides the default `backend.s3.bucket` to point at the central bootstrap bucket:

```yaml
components:
  terraform:
    tfstate-backend:
      metadata:
        component: tfstate-backend
      backend_type: s3
      backend:
        s3:
          bucket: atmos-tfstate-bootstrap-<aft-mgmt-id>-us-east-1
          region: us-east-1
          key: bootstrap/{{ .vars.account_id }}/tfstate-backend/terraform.tfstate
          role_arn: arn:aws:iam::<aft-mgmt-id>:role/AtmosCentralDeploymentRole
          encrypt: true
          use_lockfile: true
          kms_key_id: alias/atmos-tfstate-bootstrap
      vars:
        # resources this component *creates* (the target account's primary bucket)
        bucket_name: atmos-tfstate-{{ .vars.account_id }}-{{ .vars.region }}
```

All other components in the same stack inherit the default backend block, which resolves to the per-account bucket `atmos-tfstate-<account-id>-<region>`.

#### 9.3.2 Cross-account KMS key policy template

Every per-account backend CMK uses the following key policy. `<target-account-id>` is the account hosting the backend; `<aft-mgmt-id>` is the management account where the central deployment and read-only roles live.

```json
{
  "Version": "2012-10-17",
  "Id": "atmos-tfstate-key-policy",
  "Statement": [
    {
      "Sid": "EnableRootAccountPermissions",
      "Effect": "Allow",
      "Principal": { "AWS": "arn:aws:iam::<target-account-id>:root" },
      "Action": "kms:*",
      "Resource": "*"
    },
    {
      "Sid": "AllowLocalDeploymentRoleFullUse",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<target-account-id>:role/AtmosDeploymentRole"
      },
      "Action": [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowCentralDeploymentRoleFullUse",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<aft-mgmt-id>:role/AtmosCentralDeploymentRole"
      },
      "Action": [
        "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*",
        "kms:GenerateDataKey*", "kms:DescribeKey"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AllowReadAllStateRoleDecryptOnly",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<aft-mgmt-id>:role/AtmosReadAllStateRole"
      },
      "Action": [ "kms:Decrypt", "kms:DescribeKey" ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.<region>.amazonaws.com"
        }
      }
    }
  ]
}
```

Matching S3 bucket policy on `atmos-tfstate-<account-id>-<region>`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": [
        "arn:aws:s3:::atmos-tfstate-<account-id>-<region>",
        "arn:aws:s3:::atmos-tfstate-<account-id>-<region>/*"
      ],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    },
    {
      "Sid": "AllowReadAllStateRoleRead",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::<aft-mgmt-id>:role/AtmosReadAllStateRole"
      },
      "Action": [ "s3:GetObject", "s3:ListBucket", "s3:GetBucketVersioning" ],
      "Resource": [
        "arn:aws:s3:::atmos-tfstate-<account-id>-<region>",
        "arn:aws:s3:::atmos-tfstate-<account-id>-<region>/*"
      ]
    }
  ]
}
```

`AtmosReadAllStateRole` lives in aft-mgmt with an empty trust policy except for `AtmosCentralDeploymentRole` and the drift-detection workflow's OIDC subject claim. Its permissions boundary enforces read-only: deny every `s3:Put*`, `s3:Delete*`, `kms:Encrypt*`, `kms:GenerateDataKey*`. This role is what the drift aggregator and summary-collector jobs (`gha-design.md` §5.5 and the `post-plan-summary` composite) assume when they need to touch state from more than one account in a single step. Per-account `(component, stack)` plans continue to run under the regular central → target deployment chain; the read-only role is only used when a step genuinely spans accounts.

The bootstrap-bucket CMK (`alias/atmos-tfstate-bootstrap` in aft-mgmt) uses a simpler policy: root + `AtmosCentralDeploymentRole` full use + `AtmosReadAllStateRole` decrypt-only. No per-target-account grants needed — the bootstrap bucket is written only from aft-mgmt.

#### 9.3.3 Bootstrap order

The only manual-state moment in the lifecycle. Encoded as `bootstrap.yaml` (`gha-design.md` §5.8); the steps below are the concrete ordering the bootstrap workflow implements.

1. **Operator creates the bootstrap bucket + CMK locally.** From a workstation with short-lived aft-mgmt admin creds, `cd components/terraform/tfstate-backend-central && terraform init && terraform apply -var 'bootstrap=true'`. `-var 'bootstrap=true'` tells the module to use **local** state for this first pass. The apply creates `atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>`, the CMK, the bucket policy, and the access-logs target.

2. **Operator migrates the bootstrap bucket's own state into itself.** `terraform init -migrate-state -backend-config='bucket=atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>' -backend-config='key=bootstrap/self/terraform.tfstate' -backend-config='region=<region>' -backend-config='kms_key_id=alias/atmos-tfstate-bootstrap'`. Terraform prompts to copy state; confirm. Delete the local `terraform.tfstate` afterward. This is the only `migrate-state` in the system.

3. **GHA `bootstrap.yaml` runs** under access-key identity (`AtmosBootstrapUser`, §`gha-design.md` 4.2) to create the rest of the aft-mgmt plane:
   - Apply `github-oidc-provider` — state goes directly into the central bootstrap bucket under `bootstrap/<aft-mgmt-id>/github-oidc-provider/terraform.tfstate`. Reusing the bootstrap bucket here avoids a second manual step; migrating this state to aft-mgmt's primary bucket is a later housekeeping task.
   - Apply `iam-deployment-roles/central` — creates `AtmosCentralDeploymentRole`, `AtmosPlanOnlyRole`, `AtmosReadAllStateRole`. State as above.
   - Apply aft-mgmt's own `tfstate-backend` component — creates `atmos-tfstate-<aft-mgmt-id>-<region>` (primary bucket + CMK). State in the central bootstrap bucket at `bootstrap/<aft-mgmt-id>/tfstate-backend/terraform.tfstate`.

4. **For every subsequent account vended by `provision-account.yaml`** (`gha-design.md` §5.3), the state-backend step runs as job 3 under `AtmosCentralDeploymentRole`:
   - Input: the new account ID from the `account-provisioning` step.
   - Backend for this apply: the central bootstrap bucket at `bootstrap/<account-id>/tfstate-backend/terraform.tfstate`.
   - Module assumes into the target via `providers = { aws = aws.target }` using the bootstrap identity path from `iam-deployment-roles/target`.
   - Apply creates `atmos-tfstate-<account-id>-<region>`, its CMK with the policy in §9.3.2, bucket policy, KMS alias.
   - All subsequent jobs in `provision-account.yaml` (iam-deployment-roles, aws-account-settings, baseline security block, customizations) use the per-account bucket.

5. **No migration ever happens for account state.** Every workload component's first apply writes directly to the per-account bucket because it exists by the time that job runs.

#### 9.3.4 DR / dual-region — deferred

atmos-aft is single-region per account. AFT's dual-region CMK + cross-region S3 replication (`aft-analysis.md` §7.1) is not implemented. Reasons: (a) S3 is already 11-nines durable within a region; state loss risk is operator error, not infrastructure failure; (b) replicated state across regions requires a conflict-resolution story that AFT fudges by write-to-primary-only, which is the same posture single-region gives us; (c) adding cross-region replication to the per-account backend adds one CMK + one bucket + one replication role per account, multiplying blast radius for bootstrap errors.

If DR becomes a requirement, add an optional `secondary_region` variable to the `tfstate-backend` component that stamps a second bucket + CMK + replication-role in the target account. The KMS policy template in §9.3.2 applies unchanged to the secondary CMK (the replication role is already implicit via `aws_iam_role_policy_attachment "replication"`).

#### 9.3.5 Open knobs tracked elsewhere

- `tfstate-backend`'s aft-mgmt state is kept in the central bootstrap bucket as a simplification. Moving it to aft-mgmt's primary bucket (so the bootstrap bucket holds nothing but other accounts' bootstrap keys) is a housekeeping task — not on the critical path.
- The drift-detection workflow (`gha-design.md` §5.5) should verify that per-account plans continue to run under `AtmosPlanOnlyRole` (assumed into each target) and that `AtmosReadAllStateRole` is only invoked by the summary-aggregation step. Concrete IAM for `AtmosPlanOnlyRole` vs `AtmosReadAllStateRole` is in `iam-deployment-roles/central`.

---

## 10. Validation, custom commands, templates

**Validation** — Atmos supports JSON Schema (for stack shape) and OPA/Rego (for policy). `settings.validation.<name>` on a component in the catalog attaches a JSON Schema or Rego module to that component (`reference/atmos/examples/quick-start-advanced/stacks/catalog/vpc/defaults.yaml:12-36`). `atmos validate component <c> -s <s>` and `atmos validate stacks` run them. For the factory, this is where "every account must have a baseline X and tag Y" lives.

**Custom commands** — `commands:` in `atmos.yaml` defines new `atmos <verb>` subcommands with steps that are shell templates. The quick-start config ships examples for `atmos tf plan`, `atmos terraform provision`, `atmos show component` (`reference/atmos/examples/quick-start-advanced/atmos.yaml:86-179`). `component_config:` in a custom command exposes `{{ .ComponentConfig.xxx }}` so steps can compute on resolved config. Useful for bespoke workflows like `atmos factory new-account` that wraps the request-to-stack flow.

**Templates** — Go templates (with Sprig and Gomplate) are evaluated inside stack YAML when `templates.settings.enabled: true`. Available variables include `.vars`, `.atmos_component`, `.atmos_stack`, `.atmos_stack_file`, `.workspace`, `.component`, `.ComponentConfig.xxx` (inside custom commands). YAML functions like `!terraform.output`, `!store`, `!env`, `!include`, `!aws.account-id`, `!aws.organization-id` give dynamic inputs (`reference/atmos/website/docs/functions/yaml/` directory).

---

## 11. Putting it together: the AWS multi-account factory shape

Synthesizing the above into the repo layout we will actually build:

```
atmos-aft/
├── atmos.yaml                         # root config: paths, auth, stores, ci, schemas
├── vendor.yaml                        # upstream component sources (go-getter)
├── components/
│   └── terraform/
│       ├── account-provisioning/      # custom; wraps aws_servicecatalog_provisioned_product (CT Account Factory)
│       ├── tfstate-backend/           # S3 + use_lockfile per account
│       ├── aws-account-settings/      # IAM password policy, EBS default encryption
│       ├── aws-scp/                   # additional SCPs (beyond CT guardrails)
│       ├── aws-budget/                # per-account budgets
│       ├── iam-identity-center/       # permission sets, assignments
│       ├── github-oidc-provider/      # + deployment roles per account
│       ├── vpc/                       # vendored from terraform-aws-components
│       ├── … baseline components …
│       └── customizations/<name>/     # per-account customization modules (NOT YET IMPLEMENTED — see migration-from-aft.md §5)
└── stacks/
    ├── catalog/                       # reusable component defaults
    │   ├── account-provisioning/defaults.yaml
    │   ├── tfstate-backend/defaults.yaml
    │   ├── vpc/{defaults,dev,staging,prod}.yaml
    │   └── …
    ├── mixins/                        # small composable fragments
    │   ├── region/{us-east-1,us-west-2,global-region}.yaml
    │   ├── tenant/{core,plat,sandbox}.yaml
    │   └── stage/{dev,staging,prod}.yaml
    ├── orgs/
    │   └── <org>/
    │       ├── _defaults.yaml         # namespace, global tags
    │       ├── core/                  # core OU (ct-mgmt, audit, log-archive)
    │       │   ├── _defaults.yaml
    │       │   └── <account>/<region>.yaml
    │       └── plat/                  # workload OU
    │           ├── _defaults.yaml
    │           └── <account>/<region>.yaml
    ├── workflows/
    │   ├── account-factory.yaml       # bootstrap + baseline + customize sequence
    │   ├── drift.yaml
    │   └── destroy.yaml
    └── schemas/
        ├── jsonschema/                # per-component JSON Schema
        └── opa/                       # Rego policies (baseline + compliance)
```

Name template: `{{ .vars.tenant }}-{{ .vars.environment }}-{{ .vars.stage }}` (or with `namespace` prefix if we support more than one org). Stack = "this account, this region."

New account flow:
1. Operator opens a PR adding `stacks/orgs/<org>/<tenant>/<stage>/<region>.yaml` referencing the tenant/stage mixins and the catalog entries for baseline components.
2. `atmos validate stacks` and `atmos describe affected --format=matrix` run on the PR.
3. On merge, a GitHub Actions workflow runs `atmos workflow provision-account -s <stack>` which sequences: `account-provisioning` → `tfstate-backend` → `iam-roles` → baseline components → customization components. The first step invokes the Control Tower Account Factory via Service Catalog (see §12); subsequent steps assume into the new account using the auth identity chain.
4. Outputs from each step land in the SSM store (`prod/ssm` or equivalent) via the `store-outputs` hook, so later components and other stacks can reference them via `!store`.

Drift, remediation, and destroy flows are separate GHA workflows driven by the same CLI primitives.

---

## 12. What Atmos does NOT provide (gaps for the factory to fill)

Things we will need to build on top — these do not exist in the Atmos core:

1. **Account creation itself.** Atmos provisions Terraform; it does not call Organizations APIs, and in this project it must not try to — Control Tower owns the AWS Organization, OUs, the account-provisioning lifecycle, the org-level CloudTrail, baseline Config rules, and the Landing Zone. We therefore ship a custom `components/terraform/account-provisioning/` component whose only job is to wrap the `aws_servicecatalog_provisioned_product` resource against the Control Tower Account Factory product. It takes an account request (name, email, OU, SSO user) as Terraform variables and returns the new account ID as an output that downstream components consume via `!store`. The Cloudposse modules `aws-organization`, `aws-organizational-unit`, and `aws-account` are **forbidden** in this repo because they would fight Control Tower for ownership of the same resources; they must never appear in `vendor.yaml` or the components tree.
2. **Account-request → stack-file generation.** Atmos consumes stack YAML; it does not produce it from a "request." We either (a) hand-write the new `<account>/<region>.yaml`, or (b) write a small generator (GHA script, issue-form template, or `atmos` custom command) that materializes the stack files from a request file.
3. **Queueing and concurrency control across accounts.** AFT uses DynamoDB + SQS + Step Functions. Atmos has no equivalent; concurrency is whatever the driving GHA workflow imposes. The `describe affected` matrix + GHA `concurrency:` groups is the native replacement.
4. **Drift scheduling.** AFT has scheduled drift detection. Atmos has a `ci` feature set and a community GitHub Action (`cloudposse/github-action-atmos-terraform-drift-detection`) that we can adopt.
5. **Secrets rotation / long-running customizations state machines.** Anything AFT does via Step Functions has to be decomposed into GHA workflows calling Atmos commands.
6. **`after-terraform-destroy` / `before-*` hooks.** Only `after-terraform-apply` exists today (`reference/atmos/website/docs/stacks/hooks.mdx:74-76`). Lifecycle scripting before destroy or before plan must be done in the calling workflow, not via `hooks:`.
7. **Control-Tower-coexistent configuration of otherwise-standard components.** Several components we vendor from `terraform-aws-components` default to creating resources Control Tower already manages. Atmos will not stop this — it only merges the vars we give it — so the factory must set the coexistence flags explicitly in the catalog defaults:
   - `aws-config` must be configured with `create_recorder: false` and `create_iam_role: false` in every stack. The CT-provisioned recorder and role are reused; a second recorder would cause `AWS::Config::ConfigurationRecorder` duplication errors.
   - `aws-guardduty` requires a three-phase dependency chain across three separate component instances in three separate stacks, which a single `atmos terraform apply` cannot express. The factory workflow sequences them: `guardduty/delegated-admin` (in the management account) → `guardduty/root-delegation` (root → audit account delegation) → `guardduty/org-settings` (in the audit account, enables org-wide detector + auto-enable). The dependency is encoded via `settings.depends_on` and via ordered steps in an `atmos workflow`.
   - `aws-scp` is allowed only for SCPs *additional* to the CT guardrails. CT-managed SCPs must not be reimplemented.

These gaps become the explicit deliverables in the AFT-to-Atmos mapping (next document).

---

## 13. Reference: source files cited

For the review, these are the load-bearing files in `reference/atmos/`:

- `reference/atmos/examples/quick-start-advanced/atmos.yaml` — the canonical `atmos.yaml` with every relevant section.
- `reference/atmos/examples/quick-start-advanced/stacks/` — full multi-tenant, multi-region, multi-stage example; mirrors what we will build.
- `reference/atmos/examples/quick-start-advanced/vendor.yaml` — vendor manifest example.
- `reference/atmos/website/docs/stacks/stacks.mdx` — section reference.
- `reference/atmos/website/docs/stacks/imports.mdx` — imports, templates, remote sources.
- `reference/atmos/website/docs/stacks/components/metadata.mdx` — component inheritance and workspace behavior.
- `reference/atmos/website/docs/stacks/backend.mdx` — backend generation.
- `reference/atmos/website/docs/stacks/auth.mdx` — auth providers/identities/chains.
- `reference/atmos/website/docs/stacks/hooks.mdx` — lifecycle hooks and the `store` function.
- `reference/atmos/website/docs/stacks/name.mdx` — stack naming precedence.
- `reference/atmos/website/docs/components/components-overview.mdx` — implementation-vs-configuration model.
- `reference/atmos/website/docs/ci/ci.mdx` — native CI integration.
- `reference/atmos/website/docs/cli/commands/describe/describe-affected.mdx` — diff-aware deploys.
- `reference/atmos/website/docs/cli/commands/list/list-instances.mdx` — matrix output for GHA.
- `reference/atmos/website/docs/cli/commands/workflow.mdx` — workflow execution.
- `reference/atmos/website/docs/cli/configuration/workflows.mdx` — workflow file structure.
- `reference/atmos/website/docs/cli/configuration/vendor.mdx` — vendor config reference.
- `reference/atmos/website/docs/integrations/github-actions/affected-stacks.mdx` — the GHA action pattern.
- `reference/atmos/website/docs/design-patterns/stack-organization/organizational-hierarchy-configuration.mdx` — multi-tenant stack layout pattern.
- `reference/atmos/website/docs/functions/yaml/terraform.output.mdx` — data sharing across stacks.
- `reference/atmos/pkg/schema/schema.go` — Go structs that define the deep-merged configuration shape (authoritative when docs are ambiguous).
