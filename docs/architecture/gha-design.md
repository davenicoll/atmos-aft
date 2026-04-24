# GitHub Actions Workflow Design

This document specifies the GitHub Actions topology that replaces AFT's CodeBuild/CodePipeline/Step-Functions runtime substrate. Every CodeBuild project and CodePipeline enumerated in `docs/architecture/aft-analysis.md` §3 has an explicit GHA equivalent here.

**Companion docs.**
- `docs/architecture/aft-analysis.md` — AFT ground truth.
- `docs/architecture/atmos-model.md` — Atmos mental model.
- `docs/architecture/mapping.md` — AFT-to-Atmos concept mapping and the "does not map cleanly" list (§9) whose items this design closes.
- `docs/architecture/module-inventory.md` — Cloudposse modules that back the components.

**What is configurable, what is not.** The topology is deliberately a single shape with a small number of deployment-time switches. The two switches that matter are:

1. **Auth mode** — `oidc` (default) or `access_key`. Chosen per environment at bootstrap; both must work end-to-end. See §4.
2. **Management-account placement** — `separate_aft_mgmt_account: true|false`. When `true`, a dedicated atmos-aft management account hosts the central deployment role and the state backend. When `false`, the Control Tower management account hosts them. No separate workflow tree — only the target of the `AtmosCentralDeploymentRole` and the `tfstate-backend` stack location move. See §3.3.

Anything else the operator wants to vary (VCS provider, TF distribution, per-feature toggles) is Atmos stack configuration, not GHA configuration. The GHA layer stays small, generic, and reusable.

---

## 1. Design principles

1. **One repo, one dispatcher, many reusable workflows.** Every top-level workflow in `.github/workflows/` is either a trigger binding (cron, PR, push, dispatch) or a thin dispatcher that fans out to reusable workflows. Actual deployment logic lives in `.github/workflows/reusable/`. See §2.
2. **Composite actions for repeated step sequences, reusable workflows for repeated jobs.** Anywhere three or more workflows need the same credential-setup + checkout + `atmos` bootstrap sequence, it becomes a composite action under `.github/actions/`. Anywhere two or more workflows need the same end-to-end deploy-one-component job, it becomes a reusable workflow. See §7.
3. **Git is the inbox.** PR merge is `INSERT`/`MODIFY`; tombstone markers are `REMOVE`. There is no DDB stream, no custom EventBridge bus, no polling Lambda. `atmos describe affected --format=matrix` drives the matrix.
4. **Every workflow has an explicit concurrency group.** No two deploys against the same `(stack, component)` can overlap. Cross-account fan-outs are bounded by a global `ct-provisioning` group (serialises Service Catalog calls against the CT Account Factory portfolio, same reason AFT uses a FIFO SQS with `maxReceiveCount=1`). See §8.
5. **State handoff across workflows is a first-class concern.** Three mechanisms are available, in priority order: Atmos stores (SSM), GitHub Actions artifacts (planfiles), and the `atmos terraform planfile` store (S3 backend, survives cross-workflow). No workflow should rely on "the runner has the right working directory" for data exchange. See §9.
6. **OIDC is the default path; access keys are a supported fallback.** The access-key path exists for isolated operator environments (no GitHub OIDC provider in AWS, air-gapped test accounts) and for bootstrap. Both paths converge on the same `AtmosCentralDeploymentRole` identity before Atmos runs. See §4.
7. **Matrix fan-out is always chunked.** GHA caps `strategy.matrix` at 256 jobs per workflow run (`mapping.md` §9 item 4). All fan-out workflows paginate into chunks of `<= 200` and dispatch child `workflow_call` invocations per chunk. This is not an optimisation, it is the default code path. See §8.2.

---

## 2. Repo layout

### 2.1 Monorepo: decided

One repository, called `atmos-aft` by convention, hosts:

- `atmos.yaml`, `vendor.yaml`
- `components/terraform/` — Terraform root modules (vendored + first-party)
- `stacks/` — Atmos stack YAML (orgs, catalog, mixins, workflows)
- `.github/workflows/` — entry-point workflows (triggers)
- `.github/workflows/reusable/` — `workflow_call` targets
- `.github/actions/` — composite actions
- `.github/policies/` — OPA policies run by CI
- `scripts/` — one-shot operator scripts (`bootstrap.sh`, `import-existing-accounts.sh`, `chunk-matrix.sh`)
- `docs/` — this directory

**Why monorepo.** AFT's model requires four customer-facing repos (`aft-analysis.md` §6) precisely because AFT ran as Terraform + a fleet of CodePipelines watching each repo individually. We collapse all four AFT repos into one (`mapping.md` §6) because:

- Atmos resolves its configuration deep-merge across one tree. Splitting stacks across repos forces remote imports for every lookup.
- `atmos describe affected` compares a base ref to `HEAD` within one git history. Cross-repo "affected" analysis has no equivalent without stitching `git log` across repos.
- GHA permissions on `workflow_call` across repos force a trust contract (`permissions:` + reusable-workflow pinning) that adds operational weight without benefit at this scale.
- The change failure modes — "factory config changed, but a customer's customization repo didn't" — disappear. One PR, one review, one commit.

**Multi-tenant.** Teams that want isolation do it with CODEOWNERS, branch protection, and GHA environments, not separate repos.

### 2.2 Multi-repo: rejected, conditions for revisiting

We would reconsider multi-repo only if: (a) customers demand their customization code not live in the platform repo for compliance reasons (SOC2 boundary, separate legal entity); or (b) the component tree grows past ~200 vendored modules where vendor-pull times dominate CI. Neither is true at current scale.

If (a) appears, the minimum split is two repos: `atmos-aft-core` (this one) and `atmos-aft-customizations` (customer-owned, consumed via `atmos vendor pull` of a pinned ref). The `customize-*` reusable workflows in this design already accept a `customizations_source_ref` input (§6.5) so this split is non-breaking.

### 2.3 Directory shape (GHA-specific)

```
.github/
  workflows/
    pr.yaml                                  # trigger: pull_request
    push-main.yaml                           # trigger: push to main
    provision-account.yaml                   # trigger: workflow_dispatch + push-main dispatch
    customize-fleet.yaml                     # trigger: workflow_dispatch + schedule + push-main dispatch
    drift-detection.yaml                     # trigger: schedule
    import-existing-account.yaml             # trigger: workflow_dispatch
    destroy-account.yaml                     # trigger: workflow_dispatch (protected)
    bootstrap.yaml                           # trigger: workflow_dispatch (one-time)
    vendor-refresh.yaml                      # trigger: schedule + workflow_dispatch
    custom-provisioning-hook.yaml            # trigger: workflow_call (no-op default)
    notify.yaml                              # trigger: workflow_run
    ct-lifecycle-event.yaml                  # trigger: repository_dispatch (CT events)
  workflows/reusable/
    _atmos-plan.yaml                         # workflow_call
    _atmos-apply.yaml                        # workflow_call
    _atmos-destroy.yaml                      # workflow_call
    _atmos-validate.yaml                     # workflow_call
    _matrix-chunk.yaml                       # workflow_call (recursive chunker)
    _customize-global.yaml                   # workflow_call
    _customize-account.yaml                  # workflow_call
    _feature-options.yaml                    # workflow_call
    _post-provision-hook.yaml                # workflow_call
  actions/
    setup-atmos/                             # composite: install atmos + terraform
    configure-aws/                           # composite: OIDC or access-key, chain-aware
    resolve-stack/                           # composite: stack → account_id + auth context
    publish-status/                          # composite: write SSM /aft/account/<n>/status
    post-plan-summary/                       # composite: GITHUB_STEP_SUMMARY + PR comment
  policies/
    forbidden_components.rego                # aws-organization, aws-organizational-unit, aws-account
    guardduty_phase_ordering.rego            # phase 3 gated on phase 2 audit-stack instance
    naming.rego                              # stack/component naming discipline
    required_ct_flags.rego                   # aws-config recorder-off, GuardDuty CT-compat
  CODEOWNERS
```

Leading underscore (`_`) on reusable workflow filenames is convention to keep them visually separate in listings and to let glob rules in `CODEOWNERS` target entry-point workflows without matching the reusables.

---

## 3. Topology overview

### 3.1 Logical account topology

The factory always involves at least four AWS accounts:

- **CT management account** — owns the Organization, Landing Zone, the CT Account Factory Service Catalog portfolio. Hosts `AtmosDeploymentRole` for `aws-scp`, `guardduty/root`, `security-hub/org-admin-delegation`, `inspector2/delegated-admin` applies.
- **atmos-aft management account** (optional — see §3.3) — hosts `AtmosCentralDeploymentRole` and `AtmosDeploymentRole`, the tfstate backend, and the `account-provisioning` component. Co-located with CT-management if `separate_aft_mgmt_account: false` (in which case one `AtmosDeploymentRole` instance serves both CT-management and atmos-aft-management workloads).
- **Audit account** — CT-provisioned; hosts `AtmosDeploymentRole` for `guardduty/delegated-admin`, `security-hub/aggregator`, `inspector2/org-settings`, `cloudtrail-lake` applies.
- **Log-archive account** — CT-provisioned; hosts `AtmosDeploymentRole` for `cloudtrail-additional`, `centralized-logging-bucket`, `vpc-flow-logs-bucket` applies.
- **N vended accounts** — created by the factory via Service Catalog; each hosts `AtmosDeploymentRole` and the full baseline + customizations.

All five account classes host `AtmosDeploymentRole`. The four CT-managed core accounts (CT-mgmt, AFT-mgmt, audit, log-archive) get it stamped by `bootstrap.yaml` (§5.8 step 5 below) using the `OrganizationAccountAccessRole` fallback of the bootstrap identity (§4.5). Vended accounts get it stamped by `provision-account.yaml` job 4 using the `AWSControlTowerExecution` arm of the same identity. The role's trust policy is identical in all five cases — see §4.6.

### 3.2 Workflow DAG

End-to-end account lifecycle, from PR merge through customisations, with the workflow boundaries explicit:

```
                                           PR opened
                                               |
                                               v
                            +-----------------------------------+
                            |          pr.yaml                  |
                            |  (trigger: pull_request)          |
                            |                                   |
                            |  jobs:                            |
                            |   validate  -- atmos validate     |
                            |   affected  -- describe affected  |
                            |   plan      -- _atmos-plan.yaml   |
                            |   policy    -- opa eval           |
                            +-----------------------------------+
                                               |
                                        (PR merges to main)
                                               |
                                               v
                            +-----------------------------------+
                            |      push-main.yaml               |
                            |  (trigger: push branches: [main]) |
                            |                                   |
                            |  jobs:                            |
                            |   affected -- describe affected   |
                            |   route    -- classify by type    |
                            |   dispatch -- workflow_dispatch   |
                            |                into:              |
                            |                - provision-acct   |
                            |                - customize-fleet  |
                            |                - destroy-account  |
                            +-----------------------------------+
                                           |   |   |
              +----------------------------+   |   +---------------------+
              |                                |                         |
              v                                v                         v
+-----------------------+     +---------------------------+     +------------------+
| provision-account.yaml|     |  customize-fleet.yaml     |     | destroy-account  |
|   (per new stack)     |     |  (existing accounts)      |     |  (tombstoned)    |
+-----------------------+     +---------------------------+     +------------------+
          |
          | jobs (in order, via needs:):
          |
          v
+-------------------------------------------------------+
| 1. account-provisioning   -> _atmos-apply.yaml         |   state: Service Catalog
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 2. publish-account-id     -> SSM /aft/account/<n>/id   |   store-outputs hook
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 3. tfstate-backend-target -> _atmos-apply.yaml         |   (in new account)
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 4. iam-deployment-roles   -> _atmos-apply.yaml         |   AtmosDeploymentRole in target
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 5. account-baseline       -> _atmos-apply.yaml (x N)   |   password policy, EBS encryption
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 6. feature-options        -> _feature-options.yaml     |   del-default-vpc, support, trail
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 7. baseline-security                                   |   Split into serialised stages; no
|                                                        |   matrix across services or phases.
|   7a. config-rules       -> _atmos-apply.yaml          |   aws-config-rules/conformance-pack
|         (CT owns recorder; rules-only, safe to run     |   (no three-phase coupling)
|          alongside 7b-7d in per-account provisioning)  |
|                                                        |
|   7b. guardduty          -> _apply-security-service    |   service=guardduty
|         (skip_if_already_applied=true in per-account   |   target_stacks=[stack]
|          mode; short-circuits to phase 3 only)         |   needs phases 1+2 already applied
|                                                        |
|   7c. security-hub       -> _apply-security-service    |   service=security-hub
|         (runs AFTER 7b completes; sequential)          |   target_stacks=[stack]
|                                                        |
|   7d. inspector2         -> _apply-security-service    |   service=inspector2
|         (runs AFTER 7c completes; sequential)          |   target_stacks=[stack]
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 8. custom-provisioning    -> custom-provisioning-hook  |   customer extension point
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
| 9. customize-global       -> _customize-global.yaml    |   global customizations
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
|10. customize-account      -> _customize-account.yaml   |   account-specific customizations
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
|11. publish-status         -> SSM /aft/account/<n>/     |   status=customized
|                              status                    |
+-------------------------------------------------------+
          |
          v
+-------------------------------------------------------+
|12. notify                 -> workflow_run -> notify    |   (optional SNS echo)
+-------------------------------------------------------+
```

Every numbered block is a GHA job; dependencies are `needs:` edges. Job 5 is an intra-job matrix (safe: baseline components are account-local). Job 7 is serialised across its four sub-stages (7a → 7b → 7c → 7d) with no cross-service matrix; within each security-service sub-stage, `_apply-security-service.yaml` enforces its own three-phase `needs:` chain (§6.10). Jobs 9 and 10 are chunked-matrix fan-outs (§8.2).

**Identity per job.** Because `AtmosDeploymentRole` does not yet exist in the target until job 4 stamps it, the chain used differs between jobs 1–4 and jobs 5–12:

| Job | Runs in | Reusable workflow | Atmos identity | Effective role chain |
|---|---|---|---|---|
| 1. `account-provisioning` | aft-mgmt | `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` |
| 2. `publish-account-id` | aft-mgmt | (inline `store-outputs` hook) | `default` | OIDC → `AtmosCentralDeploymentRole` |
| 3. `tfstate-backend-target` | new account | **`_bootstrap-target.yaml`** (§6.9) | `bootstrap` | OIDC → `AtmosCentralDeploymentRole` → `AWSControlTowerExecution` |
| 4. `iam-deployment-roles/target` | new account | **`_bootstrap-target.yaml`** (§6.9) | `bootstrap` | OIDC → `AtmosCentralDeploymentRole` → `AWSControlTowerExecution` |
| 5. `account-baseline` | new account | `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` → **`AtmosDeploymentRole`** |
| 6. `feature-options` | new account | `_feature-options.yaml` → `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` |
| 7a. `config-rules` | new account | `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` |
| 7b. `guardduty` | new account + audit + mgmt | **`_apply-security-service.yaml`** (§6.10) `skip_if_already_applied=true` | `default` per-phase | OIDC → `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` (phase-3 only in steady state) |
| 7c. `security-hub` | new account + audit + mgmt | **`_apply-security-service.yaml`** (§6.10) `skip_if_already_applied=true`; `needs: 7b` | `default` per-phase | (same as 7b) |
| 7d. `inspector2` | new account + audit + mgmt | **`_apply-security-service.yaml`** (§6.10) `skip_if_already_applied=true`; `needs: 7c` | `default` per-phase | (same as 7b) |
| 8. `custom-provisioning` | caller-supplied | `custom-provisioning-hook.yaml` | caller-defined | caller-defined |
| 9. `customize-global` | new account | `_customize-global.yaml` → `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` |
| 10. `customize-account` | new account | `_customize-account.yaml` → `_atmos-apply.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` |
| 11. `publish-status` | aft-mgmt | composite `publish-status` | `default` | OIDC → `AtmosCentralDeploymentRole` |
| 12. `notify` | aft-mgmt | `notify.yaml` | `default` | OIDC → `AtmosCentralDeploymentRole` |

The handoff between the bootstrap chain (jobs 3–4) and the normal chain (jobs 5–12) is implicit: `_bootstrap-target.yaml` sets `ATMOS_AUTH_IDENTITY=bootstrap`, while every other reusable leaves it unset so Atmos picks `identities.default`. Stack-catalog defaults pin the `bootstrap` identity on `tfstate-backend` and `iam-deployment-roles/target` (see §4.5). There is no explicit "switch roles" step; the `needs: iam-deployment-roles` edge plus the identity pinning is what guarantees job 5 sees `AtmosDeploymentRole`.

### 3.3 Topology switch: separate atmos-aft management account

The operator chooses one of two topologies at bootstrap. Both are first-class; the only differences are:

- which account holds the `account-provisioning` stack
- which account's ARN is baked into `AtmosCentralDeploymentRole`
- which account holds the `tfstate-backend` stack

```
Topology A: separate atmos-aft management account (default for multi-tenant orgs)

   +---------------------+
   |  CT Management Acct |  --- CT Account Factory portfolio
   +----------+----------+
              ^
              | sts:AssumeRole (AWSControlTowerExecution, bootstrap only)
              |
   +----------+----------+       +----------------------+
   |  AFT Management Acct|  ---  |  tfstate-backend S3  |
   |                     |       +----------------------+
   |  AtmosCentral...Role|
   |  account-provisioning stack
   +----------+----------+
              |
              | sts:AssumeRole (AtmosDeploymentRole)
              v
   +---------------------+   +----------------------+
   |  Vended Account 1   |   |  Vended Account N    |
   |  AtmosDeploymentRole|   |  AtmosDeploymentRole |
   +---------------------+   +----------------------+


Topology B: CT management = atmos-aft management (default for single-tenant orgs)

   +---------------------+       +----------------------+
   |  CT Management Acct | ---   |  tfstate-backend S3  |
   |  = AFT Mgmt         |       +----------------------+
   |  CT Account Factory portfolio
   |  AtmosCentral...Role
   |  account-provisioning stack
   +----------+----------+
              |
              | sts:AssumeRole (AtmosDeploymentRole)
              v
   +---------------------+   +----------------------+
   |  Vended Account 1   |   |  Vended Account N    |
   |  AtmosDeploymentRole|   |  AtmosDeploymentRole |
   +---------------------+   +----------------------+
```

The GHA workflow files are identical in both topologies. The difference is one stack-config variable (`settings.aft_mgmt_account_id`) and the `AtmosCentralDeploymentRole` role ARN that `configure-aws` resolves. No branching in workflow YAML, no separate code paths.

Topology A is recommended for customers who have > 1 application team, who want deployment identities decoupled from the CT management account's blast radius, or who already operate an upstream AFT installation that kept its management account distinct. Topology B is simpler, has one fewer role to audit, and is the right default for single-team / demo / single-tenant deployments.

---

## 4. Auth paths

### 4.1 OIDC (default)

**When used.** Default for every hosted-runner execution of this repo.

**Shape.**

```
GitHub Actions runner
   | id-token: write
   v
token.actions.githubusercontent.com
   | sts:AssumeRoleWithWebIdentity
   v
AtmosCentralDeploymentRole (in atmos-aft mgmt, Topology A, or CT-mgmt, Topology B)
   | sts:AssumeRole (session = atmos-<workflow>-<run_id>)
   v
AtmosDeploymentRole (in target vended account)
```

The OIDC trust policy on `AtmosCentralDeploymentRole` restricts the `sub` claim to this repo and to specific refs:

```hcl
condition {
  test     = "StringLike"
  variable = "token.actions.githubusercontent.com:sub"
  values = [
    "repo:${var.github_org}/atmos-aft:ref:refs/heads/main",
    "repo:${var.github_org}/atmos-aft:environment:prod",
    "repo:${var.github_org}/atmos-aft:environment:aft-mgmt",
  ]
}
```

Pull-request runs from feature branches are authorised via `repo:${org}/atmos-aft:pull_request` but land in the `AtmosPlanOnlyRole` (read-only against state, no apply rights). See §4.4.

**Configuration.** `components/terraform/github-oidc-provider/` creates the OIDC IdP in aft-mgmt; `components/terraform/iam-deployment-roles/central` creates `AtmosCentralDeploymentRole` and `AtmosPlanOnlyRole`. Both are deployed once at bootstrap.

### 4.2 Access-key (opt-in)

**When used.** (a) bootstrap before the OIDC provider exists; (b) isolated operator environments without internet egress to `token.actions.githubusercontent.com`; (c) test invocations from a self-hosted runner that lacks `id-token: write` scope.

**Shape.**

```
GitHub Actions runner
   | AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY from env
   v
IAM user (AtmosBootstrapUser or operator's own)
   | sts:AssumeRole
   v
AtmosCentralDeploymentRole
   | sts:AssumeRole
   v
AtmosDeploymentRole (target)
```

The access keys belong to a named IAM user `AtmosBootstrapUser` scoped to `sts:AssumeRole` on `AtmosCentralDeploymentRole` *only*. MFA is enforced on the user; the GHA path uses a short-lived session credential obtained out of band.

**Configuration.** `configure-aws` composite action (§7.3) detects the mode:

```yaml
# .github/actions/configure-aws/action.yml (conceptual)
inputs:
  mode:                      # "oidc" | "access_key", default from env vars
    required: false
    default: ${{ env.AFT_AUTH_MODE || 'oidc' }}
  central_role_arn:
    required: true
  target_role_arn:
    required: false
  region:
    required: true

runs:
  using: "composite"
  steps:
    - if: inputs.mode == 'oidc'
      uses: aws-actions/configure-aws-credentials@v4
      with:
        role-to-assume: ${{ inputs.central_role_arn }}
        role-session-name: atmos-${{ github.workflow }}-${{ github.run_id }}
        aws-region: ${{ inputs.region }}
    - if: inputs.mode == 'access_key'
      uses: aws-actions/configure-aws-credentials@v4
      with:
        aws-access-key-id: ${{ env.AFT_BOOTSTRAP_ACCESS_KEY_ID }}
        aws-secret-access-key: ${{ env.AFT_BOOTSTRAP_SECRET_ACCESS_KEY }}
        aws-region: ${{ inputs.region }}
    - if: inputs.mode == 'access_key' && inputs.central_role_arn != ''
      run: |
        eval "$(aws sts assume-role \
          --role-arn '${{ inputs.central_role_arn }}' \
          --role-session-name 'atmos-${{ github.workflow }}-${{ github.run_id }}' \
          --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
          --output text | awk '{
            printf "export AWS_ACCESS_KEY_ID=%s\n", $1
            printf "export AWS_SECRET_ACCESS_KEY=%s\n", $2
            printf "export AWS_SESSION_TOKEN=%s\n", $3
          }')"
```

The second hop (central → target) is always driven by Atmos's `auth:` chain (`atmos-model.md` §9) inside the Terraform run, not by the action. Both modes converge on "`AtmosCentralDeploymentRole` credentials exported to the shell" before any `atmos` command runs.

### 4.3 Mode selection

Auth mode is selected at the environment level, not per workflow. Three settings:

1. `vars.AFT_AUTH_MODE` — GHA variable at the environment level (`oidc` or `access_key`). Defaults to `oidc`.
2. `secrets.AFT_BOOTSTRAP_ACCESS_KEY_ID` / `AFT_BOOTSTRAP_SECRET_ACCESS_KEY` — only required when `AFT_AUTH_MODE = access_key`.
3. `vars.ATMOS_CENTRAL_ROLE_ARN` — ARN of `AtmosCentralDeploymentRole`. Always required.

A policy check in `pr.yaml` (§5.1) fails if `AFT_AUTH_MODE != oidc` on an environment whose name matches `prod*` unless `vars.AFT_ACCESS_KEY_OVERRIDE_REASON` is set (a break-glass variable that logs to the PR summary).

### 4.5 Bootstrap identity for newly vended accounts

**When used.** `provision-account.yaml` jobs 3 (`tfstate-backend-target`) and 4 (`iam-deployment-roles/target`) in a newly vended account. See §3.2 identity-per-job table.

**Why needed.** `AtmosDeploymentRole` is stamped by job 4 itself. Jobs 3 and 4 therefore cannot use the default `central → target` chain — the target link does not exist yet. AFT solves the same problem by having its `create_role` Lambda assume `AWSControlTowerExecution` in the vended account (`aft-analysis.md` §5.1, `reference/aft/providers.tf:1-57`); this is the *only* runtime use of `AWSControlTowerExecution` in AFT. We do the same, confined to the same two components.

**Shape.**

```
GitHub Actions runner
   | id-token: write
   v
token.actions.githubusercontent.com
   | sts:AssumeRoleWithWebIdentity
   v
AtmosCentralDeploymentRole (in atmos-aft mgmt)
   | sts:AssumeRole (session = atmos-bootstrap-<stack>-<run_id>)
   v
AWSControlTowerExecution (in newly vended account, stamped by CT Account Factory)
```

For the four CT-managed accounts (CT-mgmt, AFT-mgmt, audit, log-archive) where `AWSControlTowerExecution` does not exist, the equivalent fallback is `OrganizationAccountAccessRole`. Bootstrap stamping of `AtmosDeploymentRole` into those four accounts runs inside `bootstrap.yaml` (§5.8) using the same alias configured to `OrganizationAccountAccessRole`.

**Atmos `auth:` alias.** `atmos.yaml` defines a second provider alias `target-bootstrap` that differs from `target` only in the role ARN path:

```yaml
auth:
  providers:
    target-bootstrap:
      kind: aws/assume-role
      role_arn: arn:aws:iam::{{ .vars.account_id }}:role/AWSControlTowerExecution
      chain_from: central
  identities:
    bootstrap: { provider: target-bootstrap }
```

The two bootstrap components pin this identity in their stack catalog defaults:

```yaml
# stacks/catalog/tfstate-backend/defaults.yaml
# stacks/catalog/iam-deployment-roles/target/defaults.yaml
components:
  terraform:
    <name>:
      auth:
        identities:
          bootstrap: { default: true }
```

Every other component defaults to `identities.default` (`target` provider). The first applies of the two bootstrap stacks therefore automatically resolve to `AWSControlTowerExecution`; from job 5 onwards, Atmos resolves to `AtmosDeploymentRole` with no workflow change.

**Central role permissions.** `AtmosCentralDeploymentRole`'s attached policy must allow `sts:AssumeRole` on both:

```json
{
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": [
    "arn:aws:iam::*:role/AtmosDeploymentRole",
    "arn:aws:iam::*:role/AWSControlTowerExecution",
    "arn:aws:iam::*:role/OrganizationAccountAccessRole"
  ]
}
```

The `AWSControlTowerExecution` / `OrganizationAccountAccessRole` arms are runtime-scoped to the two bootstrap components; `AtmosDeploymentRole` is used for everything else. This mirrors AFT's `AWSAFTAdmin` → `AWSAFTExecution` + `AWSControlTowerExecution` fan-out (`aft-analysis.md:219-224`).

**Caller behaviour.** The `_bootstrap-target.yaml` reusable workflow (§6.9) is the one place `ATMOS_AUTH_IDENTITY=bootstrap` is set. All other reusables (including `_atmos-apply.yaml`) leave the env unset. Callers of `_bootstrap-target.yaml` are: `provision-account.yaml` jobs 3 + 4, and `bootstrap.yaml` stamping `AtmosDeploymentRole` into the four CT-managed core accounts.

### 4.4 Read-only vs deploy identities

Separate roles for read-only (PR) and deploy (main push / dispatch):

| Role | Purpose | Trust subject | Permissions |
|---|---|---|---|
| `AtmosCentralDeploymentRole` | Apply, destroy | `main`, `environment:prod`, `environment:aft-mgmt` | `AdministratorAccess` chainable to `AtmosDeploymentRole` |
| `AtmosPlanOnlyRole` | Plan (PR runs) | `pull_request` | Read-only state S3/KMS + `sts:AssumeRole` on `AtmosDeploymentRole-ReadOnly` |
| `AtmosDeploymentRole` (in targets) | Deploy | Trusts `AtmosCentralDeploymentRole` | `AdministratorAccess` |
| `AtmosDeploymentRole-ReadOnly` (in targets) | Plan | Trusts `AtmosPlanOnlyRole` | `ReadOnlyAccess` + `organizations:Describe*` |

This replicates AFT's implicit separation between CodePipeline stages that `assume AWSAFTAdmin` (full) and buildspecs that only need state reads, with the distinction made explicit at the IAM layer.

### 4.6 Role placement matrix

This section is the canonical answer to "which IAM role lives in which account, created by what, trusted by whom, used for what." It covers both the atmos-aft-management-hosted central plane and the per-account `AtmosDeploymentRole`.

#### 4.6.1 Roles at a glance

| Role | Home account | Created by | Trusted principals | Permissions | Used for |
|---|---|---|---|---|---|
| `AtmosCentralDeploymentRole` | atmos-aft mgmt | `iam-deployment-roles/central` (bootstrap.yaml step 3) | GitHub OIDC provider (`token.actions.githubusercontent.com`) with `sub` pinned to this repo + protected refs | `AdministratorAccess` + `sts:AssumeRole` on `*:role/AtmosDeploymentRole`, `*:role/AWSControlTowerExecution`, `*:role/OrganizationAccountAccessRole` | Fan-out root for every deploy/destroy workflow; first hop after OIDC. |
| `AtmosPlanOnlyRole` | atmos-aft mgmt | `iam-deployment-roles/central` (bootstrap.yaml step 3) | GitHub OIDC (`sub:pull_request`) only | Read state S3/KMS + `sts:AssumeRole` on `*:role/AtmosDeploymentRole-ReadOnly` | `pr.yaml` plan job; never writes. |
| `AtmosReadAllStateRole` | atmos-aft mgmt | `iam-deployment-roles/central` (bootstrap.yaml step 3) | `AtmosCentralDeploymentRole` only (same-account trust) | **Decrypt + read** only: `kms:Decrypt`, `kms:DescribeKey` (conditioned on `kms:ViaService=s3.<region>.amazonaws.com`); `s3:GetObject`, `s3:ListBucket`, `s3:GetBucketVersioning`. Permissions-boundary denies `s3:Put*`, `s3:Delete*`, `kms:Encrypt*`, `kms:GenerateDataKey*`, `kms:ReEncrypt*`. | Drift-summary aggregation across all target accounts' state buckets (`drift-detection.yaml`, post-plan-summary composite). Per-account CMK + S3 bucket policies grant it access — see `atmos-model.md §9.3.2`. |
| `AtmosDeploymentRole` | CT-mgmt, AFT-mgmt, audit, log-archive, every vended account | CT-core placements: `bootstrap.yaml` step 5 via `_bootstrap-target.yaml`. Vended placements: `provision-account.yaml` job 4 via `_bootstrap-target.yaml`. | `AtmosCentralDeploymentRole` (with `sts:ExternalId` guardrail on the four CT-core variants) | `AdministratorAccess` | Every component apply in jobs 5–12 of `provision-account.yaml` and every bootstrap/customize/destroy workflow's target-account step. |
| `AtmosDeploymentRole-ReadOnly` | Every vended account (and CT-core accounts, same stamping path) | Same as `AtmosDeploymentRole` (same `iam-deployment-roles/target` component, extra role resource) | `AtmosPlanOnlyRole` | `ReadOnlyAccess` + `organizations:Describe*` | `pr.yaml` plan job per-account reads. |
| `AWSControlTowerExecution` | Every CT-vended account (audit, log-archive, all vended — **not** CT-mgmt) | Control Tower Account Factory (not Atmos) | CT management account root | Effectively admin (CT-owned) | **Bootstrap identity only** — first hop into a newly vended account to stamp `AtmosDeploymentRole` and `tfstate-backend`. After stamping, not used again. |
| `OrganizationAccountAccessRole` | Every account vended via Organizations (all four CT-core accounts, most legacy accounts) | Organizations (automatic) or account-create API | Organizations master account root | Admin | Bootstrap identity for the four CT-core placements in `bootstrap.yaml` step 5. Preferred over `AWSControlTowerExecution` because it exists in CT-mgmt too. |

The CT-vended bootstrap roles (`AWSControlTowerExecution`, `OrganizationAccountAccessRole`) are runtime-scoped to the two bootstrap components (`iam-deployment-roles/target`, `tfstate-backend`) via Atmos catalog pinning (§4.5). Every other component resolves to `AtmosDeploymentRole`.

#### 4.6.2 `AtmosDeploymentRole` per-account placement

`AtmosDeploymentRole` lives in **every** account Atmos applies against, not just vended accounts. §3.1 enumerates the five classes; the table below names which components need it per class. If a class has no row, the role is absent there.

| Account class | Components that require `AtmosDeploymentRole` (non-exhaustive) | Stamping workflow |
|---|---|---|
| CT management | `aws-scp`, `guardduty/root`, `security-hub/org-admin-delegation`, `inspector2/delegated-admin`, `identity-center-permission-sets` (§2.5 row 41), EventBridge rule for `controltower-event-bridge` (row 8) | `bootstrap.yaml` step 5a |
| atmos-aft management | `account-provisioning`, `iam-deployment-roles/central`, `aft-ssm-parameters`, `controltower-event-bridge`, all observability | `bootstrap.yaml` step 5b (only when `separate_aft_mgmt_account=true`; otherwise the CT-mgmt instance covers both) |
| Audit | `guardduty/delegated-admin`, `security-hub/aggregator`, `inspector2/org-settings`, `cloudtrail-lake` (if adopted — see `module-inventory.md` §7 Q7), `vpc-flow-logs-bucket` | `bootstrap.yaml` step 5c |
| Log-archive | `cloudtrail-additional`, `centralized-logging-bucket` | `bootstrap.yaml` step 5d |
| Vended | Every component in `provision-account.yaml` jobs 5–12 | `provision-account.yaml` job 4 |

**Trust policy template.** The role's assume-role policy is identical in all five cases. The only variant is the `sts:ExternalId` condition, which is set on the four CT-core placements (an extra guardrail given those accounts existed before Atmos) and omitted on vended accounts (the account ID itself is the fresh-vend uniqueness signal).

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "AllowAssumeFromCentral",
    "Effect": "Allow",
    "Principal": {
      "AWS": "arn:aws:iam::${aft_mgmt_account_id}:role/AtmosCentralDeploymentRole"
    },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": {
        "sts:ExternalId": "${atmos_external_id}"
      },
      "StringLike": {
        "aws:userid": "AROA*:atmos-*"
      }
    }
  }]
}
```

- `${aft_mgmt_account_id}` — the account hosting `AtmosCentralDeploymentRole`.
- `${atmos_external_id}` — a static per-org UUID stored in GHA vars (`ATMOS_EXTERNAL_ID`). Required in the four CT-core placements; optional (and omitted) in vended-account placements.
- `aws:userid` match on `atmos-*` session names enforces that assumptions are via Atmos-tagged sessions only (the `configure-aws` composite sets `role-session-name=atmos-<workflow>-<run_id>`).

**Policy attached.** `AdministratorAccess` managed policy in all five classes. Justification: `AtmosDeploymentRole` is the last hop; any capability restriction belongs at `AtmosCentralDeploymentRole`'s resource-list on `sts:AssumeRole` (already pinned to `*:role/AtmosDeploymentRole` via §4.5), or in SCPs on the OU. A per-component least-privilege boundary is explicitly out of scope — see §12.

**Stamping path for CT-core accounts.** The four CT-managed accounts predate Atmos, so the bootstrap chain must reach into them before `AtmosDeploymentRole` exists:

```
GitHub Actions runner (bootstrap environment)
   | id-token: write
   v
AtmosCentralDeploymentRole (in atmos-aft mgmt, created by bootstrap.yaml step 3)
   | sts:AssumeRole
   v
OrganizationAccountAccessRole (in CT-mgmt / audit / log-archive — present since Organization creation)
   | terraform apply components/terraform/iam-deployment-roles/target
   v
AtmosDeploymentRole (now exists in the target core account)
```

For the three CT-vended core accounts (audit, log-archive, and the atmos-aft management account if CT vended it), `AWSControlTowerExecution` is also usable; the bootstrap workflow prefers `OrganizationAccountAccessRole` because it exists in all four classes (CT-mgmt included, where `AWSControlTowerExecution` does not). The `_bootstrap-target.yaml` `fallback_role` input (§6.9) overrides on a per-call basis when needed.

**Per-account stack.** Each CT-core account gets a stack under `stacks/orgs/<org>/core/<account>/` with at minimum:

```yaml
# stacks/orgs/<org>/core/ct-mgmt/us-east-1.yaml
components:
  terraform:
    iam-deployment-roles/target:
      vars:
        trusted_central_role_arn: !store ssm /atmos/central/role-arn
        atmos_external_id: !env ATMOS_EXTERNAL_ID
      auth:
        identities:
          bootstrap: { default: true }   # pin bootstrap identity; same as §4.5
```

Analogous files under `aft-mgmt/`, `audit/`, `log-archive/`. The `iam-deployment-roles/target` component body is the same as the vended-account variant (§3 of `module-inventory.md`); only the stack YAML differs.

---

## 5. Trigger-bound workflows (entry points)

Each entry-point workflow is listed here with explicit triggers, inputs, outputs, and the reusable workflows / composite actions it calls.

### 5.1 `pr.yaml`

**Purpose.** Validate every PR. AFT equivalent: none (AFT runs `terraform plan` only at apply time). This is a deliberate positive delta.

**Triggers.**
```yaml
on:
  pull_request:
    branches: [main]
    paths:
      - 'atmos.yaml'
      - 'vendor.yaml'
      - 'components/**'
      - 'stacks/**'
      - '.github/**'
```

**Inputs.** None (PR event carries `base_ref`, `head_ref`).

**Outputs.** PR comment with plan summary (via `post-plan-summary` composite); PR check pass/fail.

**Concurrency.**
```yaml
concurrency:
  group: pr-${{ github.event.pull_request.number }}
  cancel-in-progress: true
```

**Jobs.**

| Job | Calls | Purpose |
|---|---|---|
| `setup` | `.github/actions/setup-atmos` | Install Atmos + Terraform + resolve versions from `atmos.yaml`. |
| `validate` | `atmos validate stacks` | Fail on malformed stack YAML. |
| `policy` | OPA `stacks/schemas/opa/*.rego` + `.github/policies/*.rego` | Enforce CT coexistence (§3 of `mapping.md`), forbidden components (`aws-organization`, `aws-organizational-unit`, `aws-account`), auth-mode override rule (§4.3). |
| `affected` | `atmos describe affected --format=matrix -o $GITHUB_OUTPUT --include-dependents=true --include-spacelift-admin-stacks=false` | Compute `(component, stack)` matrix plus deletions. |
| `plan` | `_atmos-plan.yaml` (chunked matrix) | One `atmos terraform plan <component> -s <stack> --ci` per affected instance. Uploads each plan to S3 store (§9.3) keyed by `pr-<num>-<sha>-<stack>-<component>`. |
| `summary` | `.github/actions/post-plan-summary` | Aggregate all plans into one PR comment; fail job if OPA found a violation. |

**Auth.** `AtmosPlanOnlyRole` in OIDC mode. Every PR check uses the read-only identity — no PR can apply anything.

### 5.2 `push-main.yaml`

**Purpose.** Route merged PRs to the right deploy workflow. AFT equivalent: the CloudWatch Events rule on the `main` branch of the account-request repo (`aft-analysis.md` §3.2 pipeline 1) plus the `AccountRequestRecordHandler.process_request()` router (`aft-analysis.md` §2 phase A).

**Triggers.**
```yaml
on:
  push:
    branches: [main]
    paths:
      - 'stacks/**'
      - 'components/**'
      - 'vendor.yaml'
```

**Inputs.** None.

**Outputs.**
- `affected_new` — list of `(stack)` pairs for stacks that did not exist in `base_ref` (new accounts).
- `affected_modified` — list for stacks whose `vars` changed but file existed.
- `affected_destroyed` — list for stacks whose `metadata.deleted: true` was newly set (tombstone semantics; see `mapping.md` §9 item 1).
- `affected_customizations` — list of component instances under `customizations/*` that changed.

**Concurrency.**
```yaml
concurrency:
  group: push-main
  cancel-in-progress: false
```

Serial. This is the single entry point that mutates state; concurrency=1 avoids merge-order races with the provisioning fan-out.

**Permissions.** The default `GITHUB_TOKEN` is issued with `contents: read` and does **not** carry `actions: write`, so `gh workflow run` (REST `POST /repos/.../actions/workflows/.../dispatches`) is rejected unless the workflow asks for it explicitly:
```yaml
permissions:
  contents: read
  id-token: write     # for OIDC auth on the describe/route jobs
  actions: write      # required so the dispatch-* jobs can fire child workflows
```

Audit trail implication: dispatched runs show `github-actions[bot]` (or the PAT owner, if a PAT is used instead) as the `actor`, not the human who merged the PR. The merging human is still recoverable from `github.event.head_commit.author` in the logs of `push-main` itself; the child workflow preserves the merge SHA via `github.sha` of the dispatched ref. `publish-status` (§7.4) writes both `triggered_by_sha` and `triggered_by_commit_author` into SSM so the audit trail is complete end-to-end.

PAT alternative: a fine-grained PAT scoped to `actions: write` + `contents: read` on this repo, stored as `secrets.WORKFLOW_DISPATCH_PAT`, preserves the human actor on dispatched runs (runs show the PAT owner). Rejected by default because rotating a PAT is operator toil and the SSM-recorded `triggered_by_commit_author` is sufficient for our audit needs. The design is configurable — if `secrets.WORKFLOW_DISPATCH_PAT` is set, the `dispatch-*` jobs use it via `GH_TOKEN=${{ secrets.WORKFLOW_DISPATCH_PAT }}`; otherwise they fall back to `GITHUB_TOKEN` with the explicit `actions: write` scope above.

**Jobs.**

| Job | Calls | Purpose |
|---|---|---|
| `affected` | `atmos describe affected --format=json` | Compute diff between `HEAD` and `HEAD^`. |
| `route` | `scripts/classify-affected.sh` | Partition `affected` into the four output buckets above. |
| `dispatch-provision` | `gh workflow run provision-account.yaml --ref main -f stack=<n>` per new stack | Fire-and-track N provisioning runs. Uses `gh run watch` with `|| true` to not fail push-main on individual provision failure (they trigger their own alarms). |
| `dispatch-customize` | `gh workflow run customize-fleet.yaml --ref main -f scope=changed` | Fire one customisation sweep for modified customisation instances. |
| `dispatch-destroy` | `gh workflow run destroy-account.yaml --ref main -f stack=<n>` per tombstoned stack | Requires environment `destroy` approval downstream; this job only triggers. |

The dispatch step uses `workflow_dispatch` rather than `workflow_call` for two reasons. First, `workflow_call` attaches the callees to the caller's run, which serialises the DAG under `push-main`'s concurrency (`push-main`, single-lane) and blocks the next merge until the entire fleet's dispatch tree drains — unacceptable when provisioning a single account can take 20-30 min. Per-call `concurrency:` overrides in the reusable workflow can work around the shared-lease issue, but not the run-lifetime coupling: a single failed callee fails the parent, which would cascade-fail unrelated provision runs triggered by the same merge. Second, the dispatched runs surface as first-class workflow runs in the Actions UI, which is how operators navigate long-running provisioning; nested `workflow_call` collapses into a single run with many jobs, which scales poorly past a dozen targets.

**Auth.** `AtmosCentralDeploymentRole` in OIDC mode, read-only permissions suffice for `describe affected`; no apply happens here.

### 5.3 `provision-account.yaml`

**Purpose.** Full end-to-end provisioning lifecycle for one new account. AFT equivalent: the entire `aft-account-provisioning-framework` SFN plus `aft-create-pipeline` CodeBuild plus the first run of the per-account customizations pipeline (`aft-analysis.md` §2 phases D and E, §3.1 projects 3, 4, 5).

**Triggers.**
```yaml
on:
  workflow_dispatch:
    inputs:
      stack:
        description: "Stack name (e.g., plat-ue1-prod)"
        required: true
        type: string
      skip_customizations:
        description: "Skip global and account customisations"
        required: false
        type: boolean
        default: false
      skip_feature_options:
        description: "Skip feature-options (delete-default-vpc, support, trail)"
        required: false
        type: boolean
        default: false
```

**Inputs.** `stack`, `skip_customizations`, `skip_feature_options`.

**Outputs.**
- `account_id` — newly vended account ID, published to step summary and written to SSM.
- `status` — one of `provisioning | baseline-deployed | customized | failed`.

**Concurrency.**
```yaml
concurrency:
  group: provision-${{ inputs.stack }}
  cancel-in-progress: false
```
Plus a global `ct-provisioning` group on the `account-provisioning` job only (§8.1).

**Jobs.** See §3.2 DAG for the full job list plus the identity-per-job table. Every non-trivial job is a `workflow_call` into `_atmos-apply.yaml` (default identity) **or** `_bootstrap-target.yaml` (jobs 3 and 4 only; bootstrap identity — see §4.5 and §6.9) with stack-specific `component` input.

**Identity handoff.** Jobs 3 and 4 run under the bootstrap chain `OIDC → AtmosCentralDeploymentRole → AWSControlTowerExecution` because `AtmosDeploymentRole` does not yet exist in the target account. After job 4 stamps `AtmosDeploymentRole`, jobs 5–12 implicitly switch to the normal `OIDC → AtmosCentralDeploymentRole → AtmosDeploymentRole` chain because they call `_atmos-apply.yaml` (which leaves `ATMOS_AUTH_IDENTITY` unset) while their stack catalogs leave `identities.default` in place. There is no explicit role-switch step — the dependency ordering (`needs: iam-deployment-roles`) plus stack-catalog identity pinning on the two bootstrap components is what guarantees the transition.

**Environment.** `prod` or `aft-mgmt` depending on `stack` pattern. Required reviewers configured on `prod` (§11).

**Auth.** OIDC by default; mode read from environment `vars.AFT_AUTH_MODE`. Central-role attached policy must grant `sts:AssumeRole` on `AtmosDeploymentRole`, `AWSControlTowerExecution`, and `OrganizationAccountAccessRole` (see §4.5).

### 5.4 `customize-fleet.yaml`

**Purpose.** Run customization components against some or all existing accounts. AFT equivalent: the `aft-invoke-customizations` SFN (`aft-analysis.md` §2 phase E step 10, §3.1 projects 3 and 4).

**Triggers.**
```yaml
on:
  workflow_dispatch:
    inputs:
      scope:
        description: "all | changed | stack:<name> | component:<n>"
        required: true
        default: changed
        type: string
      dry_run:
        description: "plan only, do not apply"
        required: false
        default: false
        type: boolean
  schedule:
    - cron: '0 6 * * 1'   # Mondays 06:00 UTC — weekly reconciliation
```

**Inputs.** `scope`, `dry_run`.

**Outputs.** Per-instance summary written to `$GITHUB_STEP_SUMMARY`.

**Concurrency.**
```yaml
concurrency:
  group: customize-fleet-${{ inputs.scope }}
  cancel-in-progress: false
```
Plus a global `customize-fleet-global` group (§8.1) that cannot overlap with `provision-account-*` groups.

**Jobs.**

| Job | Calls | Purpose |
|---|---|---|
| `resolve-targets` | `atmos list instances --component 'customizations/*' --format json` filtered by `scope` | Build target list. |
| `chunk` | `_matrix-chunk.yaml` | Split targets into chunks of 200 (§8.2). |
| `customize-global` | `_customize-global.yaml` (one call per chunk) | Runs `customizations/global` against chunk. |
| `customize-account` | `_customize-account.yaml` (one call per chunk) | Runs `customizations/<name>` against chunk. |
| `report` | composite `post-plan-summary` | Aggregate and echo. |

**Environment.** `prod`.

### 5.5 `drift-detection.yaml`

**Purpose.** Nightly drift scan across all stacks. AFT equivalent: none (AFT has no built-in drift detection; see `mapping.md` §9 item 7).

**Triggers.**
```yaml
on:
  schedule:
    - cron: '0 2 * * *'    # 02:00 UTC daily
  workflow_dispatch: {}
```

**Inputs.** None.

**Outputs.** GH issue created (or updated) per drift event; Slack/SNS notifier optional via `notify.yaml`.

**Concurrency.**
```yaml
concurrency:
  group: drift-detection
  cancel-in-progress: true   # new run supersedes stale one
```

**Jobs.** Matrix of `_atmos-plan.yaml` across every `(component, stack)` instance. Each plan is run with the `AtmosPlanOnlyRole`. Any non-empty plan opens/updates a GH issue tagged `drift` with the plan diff embedded.

### 5.6 `import-existing-account.yaml`

**Purpose.** `terraform import` a pre-existing CT-vended account into `account-provisioning` state. AFT equivalent: the `INSERT for existing CT account` router branch (`aft-analysis.md` §2 phase A) which imports instead of calling Service Catalog.

**Triggers.**
```yaml
on:
  workflow_dispatch:
    inputs:
      stack:
        required: true
        type: string
      servicecatalog_provisioned_product_id:
        required: true
        type: string
```

**Inputs.** `stack`, `servicecatalog_provisioned_product_id`.

**Outputs.** Updated state for `account-provisioning` in the target stack.

**Concurrency.** `import-${{ inputs.stack }}`.

**Jobs.**
- `lookup` — `aws servicecatalog describe-provisioned-product` to verify the product ID exists.
- `import` — `atmos terraform import account-provisioning aws_servicecatalog_provisioned_product.this ${{ inputs.servicecatalog_provisioned_product_id }} -s ${{ inputs.stack }}`.
- `plan` — `_atmos-plan.yaml` to confirm clean plan after import.
- `summary` — post result to step summary.

**Environment.** `aft-mgmt`.

### 5.7 `destroy-account.yaml`

**Purpose.** Tear down a tombstoned account. AFT equivalent: the `REMOVE` router branch + `aft-cleanup-resources` Lambda (`aft-analysis.md` §2 phase A).

**Triggers.**
```yaml
on:
  workflow_dispatch:
    inputs:
      stack:
        required: true
        type: string
      confirm_account_id:
        description: "Must match resolved account_id as a second-factor check"
        required: true
        type: string
```

**Inputs.** `stack`, `confirm_account_id`.

**Outputs.** Status = `destroyed` in SSM.

**Concurrency.** `destroy-${{ inputs.stack }}`.

**Jobs.** Reverse of provisioning, each step calls `_atmos-destroy.yaml`:

| # | Job | Component / action | Purpose |
|---|---|---|---|
| 1 | `verify` | read `core-ssm` | Verify `confirm_account_id` matches SSM-recorded `account_id` for the stack; abort if not. |
| 2 | `customize-down` | `customizations/*` | Remove per-account customisations. |
| 3 | `baseline-down` | `account-baseline`, `baseline-security/*` | Roll back baseline and security-service member settings (phase 3 of §6.10). Phases 1 and 2 of the security services are **never** torn down by an account destroy — they are fleet-wide and owned by `customize-fleet.yaml`. |
| 4 | `feature-options-down` | `feature-options/*` | Reverse delete-default-vpc / support / trail flags. |
| 5 | `iam-roles-down` | `iam-deployment-roles/target` | Remove `AtmosDeploymentRole` from target account. |
| 6 | `tfstate-backend-down` | `tfstate-backend/target` | Remove per-account state bucket (state is now only in central). |
| 7 | `account-provisioning-destroy` | `account-provisioning` | `terraform destroy` on the `aws_servicecatalog_provisioned_product` — Service Catalog queues CT's async account closure. Publishes the Service Catalog `record_id` to step summary and writes `status=closing` to `/aft/account/<n>/status`. |
| 8 | `wait-for-suspended` | bash + `aws organizations describe-account` | Poll until CT's async closure completes. See below. |
| 9 | `finalize` | SSM writes | On success, writes `status=destroyed`, `destroyed_at=<iso8601>`, `service_catalog_record_id=<id>` to `/aft/account/<n>/`. On timeout, writes `status=destroy-stuck` and opens a GitHub issue tagged `destroy-stuck` with the record ID and the last-observed account status. |

**`wait-for-suspended` polling semantics.**

Control Tower closes an account asynchronously after Service Catalog accepts the terminate call (`aft-analysis.md` §2 phase A). The GHA workflow polls both ends of the handoff:

```yaml
wait-for-suspended:
  needs: account-provisioning-destroy
  timeout-minutes: 45
  steps:
    - name: Poll Service Catalog record
      run: |
        # Phase A: Service Catalog record reaches SUCCEEDED
        aws servicecatalog describe-record \
          --id "${{ needs.account-provisioning-destroy.outputs.record_id }}" \
          --query 'RecordDetail.Status' --output text
      # retries every 30s for 10 min, fails fast on FAILED

    - name: Poll Organizations account status
      run: |
        # Phase B: aws_organizations_account.status == SUSPENDED
        aws organizations describe-account \
          --account-id "${{ inputs.confirm_account_id }}" \
          --query 'Account.Status' --output text
      # retries every 60s for up to 30 min
```

Total budget 45 min (AWS docs: CT account closure is typically 15-30 min, tail to ~40 min observed). On `timeout-minutes` the job fails, the `finalize` job runs via `if: always()` and writes `status=destroy-stuck`. A separate `reconcile-destroyed.yaml` scheduled workflow (§5.11.1) periodically rescans `status=destroy-stuck` accounts and, if CT has since completed, promotes them to `destroyed`.

**Cooldown guard on re-provision.** Even with the polling job, re-adding the same stack file (same account email) within 7 days of closure races CT's `SUSPENDED → ready-for-reuse` window. `pr.yaml` `policy` job rejects any PR that adds a stack whose email matches an SSM record in `status=closing` or has `destroyed_at` within 7 days unless the PR carries a `cooldown-override` label (requires `AtmosAdmin` team approval).

**Environment.** `destroy` — requires two human reviewers (§11.2). The `confirm_account_id` input is verified against `!store core-ssm account-provisioning account_id` to prevent wrong-account destroy.

### 5.8 `bootstrap.yaml`

**Purpose.** One-time: create `github-oidc-provider` and `iam-deployment-roles/central` before any other workflow can run. AFT equivalent: `terraform apply` of the AFT root module against an aft-mgmt account with short-lived privileged creds.

**Triggers.** `workflow_dispatch` only.

**Inputs.**
- `aft_mgmt_account_id`
- `aft_mgmt_region`
- `separate_aft_mgmt_account` (boolean)
- `terraform_distribution` (`oss` or `tfc`)

**Outputs.** `AtmosCentralDeploymentRole` ARN written to step summary (the operator copies it into `vars.ATMOS_CENTRAL_ROLE_ARN` for subsequent runs).

**Concurrency.** `bootstrap` (global; only one bootstrap ever in flight).

**Jobs.** Ordered to match `atmos-model.md` §9.3.3. The operator must have run the two manual pre-steps (§9.3.3 steps 1–2) before dispatching this workflow; the central bootstrap bucket + CMK must exist and hold their own state.

1. `configure-aws` in access-key mode (bootstrap has no OIDC provider yet, by definition).
2. `_atmos-apply.yaml` targeting `github-oidc-provider` in stack `aft-mgmt-${{ inputs.aft_mgmt_region }}`. Backend: central bootstrap bucket, key `bootstrap/<aft-mgmt-id>/github-oidc-provider/terraform.tfstate`.
3. `_atmos-apply.yaml` targeting `iam-deployment-roles/central` in the same stack. Creates `AtmosCentralDeploymentRole`, `AtmosPlanOnlyRole`, `AtmosReadAllStateRole`. Backend: central bootstrap bucket.
4. `_atmos-apply.yaml` targeting `tfstate-backend` (aft-mgmt's own primary bucket) in the same stack. Backend: central bootstrap bucket at `bootstrap/<aft-mgmt-id>/tfstate-backend/terraform.tfstate`. Apply creates `atmos-tfstate-<aft-mgmt-id>-<region>` + CMK.
5. **Stamp `AtmosDeploymentRole` into the four CT-managed core accounts** (placement rationale + trust policy: §4.6). Sequential, one call to `_bootstrap-target.yaml` (§6.9) per account with `component=iam-deployment-roles/target` and `fallback_role=OrganizationAccountAccessRole`. State for each of these applies is kept in the central bootstrap bucket at `bootstrap/<account-id>/iam-deployment-roles/terraform.tfstate`, since per-account state buckets in the core accounts don't exist yet — step 6 creates them.
    - 5a. CT-mgmt account.
    - 5b. atmos-aft mgmt account — **skipped** when `separate_aft_mgmt_account=false` (same account as 5a).
    - 5c. Audit account.
    - 5d. Log-archive account.

   Sequential, not parallel: `AtmosCentralDeploymentRole`'s cross-account `sts:AssumeRole` policy was created in step 3, so transient IAM propagation is the likely failure mode. Serial runs give per-account failure attribution and avoid thundering-herd on the policy evaluator.

6. **Stamp per-account `tfstate-backend` into each of the four CT-managed core accounts.** Same four-call pattern as step 5 (same skip rule for 5b/6b when `separate_aft_mgmt_account=false`), but `component=tfstate-backend`. Each apply creates the core account's primary state bucket + CMK per `atmos-model.md` §9.3. State for this apply is kept at `bootstrap/<account-id>/tfstate-backend/terraform.tfstate` in the central bootstrap bucket; migrating into the bucket it just created is a housekeeping item, not a bootstrap step.

7. **Fleet-security phase 1+2 initialisation.** For each of `guardduty`, `security-hub`, `inspector2`, call `_apply-security-service.yaml` (§6.10) with `mgmt_stack=<ct-mgmt-stack>`, `audit_stack=<audit-stack>`, `target_stacks='[]'` (empty), `skip_if_already_applied=false`. This runs phases 1 and 2 of each service (delegated-admin registration in the CT management account, then org-wide config in the audit account). Phase 3 is skipped because there are no member accounts to enrol yet. The three services are called sequentially (guardduty → security-hub → inspector2) to avoid contention on the audit account's IAM. These applies use the default (non-bootstrap) identity — `AtmosDeploymentRole` now exists in CT-mgmt and audit (stamped in step 5). **Preconditions:** the CT audit and log-archive core accounts must already exist as Control Tower core accounts (enforced by CT landing-zone setup out-of-band, before this workflow runs). The bootstrap workflow fails fast if `aws organizations describe-account --account-id <audit>` does not return `Status=ACTIVE`.

8. Write to step summary: `AtmosCentralDeploymentRole` ARN; bootstrap bucket name; `AtmosDeploymentRole` ARN in each of the four core accounts (three when `separate_aft_mgmt_account=false`); per-account primary tfstate bucket names; per-service `<service>-delegated-admin` status.

**Not in this workflow.** Migration of any state from the central bootstrap bucket into aft-mgmt's primary bucket. `github-oidc-provider` and `iam-deployment-roles/central` state stays in the bootstrap bucket — tracked as housekeeping in `atmos-model.md` §9.3.5.

**Environment.** `bootstrap` — requires admin approval; access-key pair lives in environment secrets and is rotated after bootstrap completes.

### 5.9 `vendor-refresh.yaml`

**Purpose.** Update vendored components and open a PR. Not AFT-equivalent; positive delta.

**Triggers.**
```yaml
on:
  schedule:
    - cron: '0 3 * * 1'   # Mondays 03:00 UTC
  workflow_dispatch: {}
```

**Jobs.**
- `atmos vendor pull`
- `git diff --exit-code` — if no changes, exit.
- Create PR with changes, labels `vendor-refresh`, `automated`.

**Auth.** No AWS access required; only `GITHUB_TOKEN` with PR creation scope.

### 5.10 `custom-provisioning-hook.yaml`

**Purpose.** Customer-owned extension point invoked by `provision-account.yaml` job 8. AFT equivalent: `aft-account-provisioning-customizations` SFN (`aft-analysis.md` §2 phase D and §6.2).

**Triggers.**
```yaml
on:
  workflow_call:
    inputs:
      stack:       { required: true, type: string }
      account_id:  { required: true, type: string }
    secrets:
      SERVICENOW_TOKEN: { required: false }
```

**Default body.** One job with one step `echo "no-op"`. Customers replace this file with their own hook logic (approval, ServiceNow ticket creation, external compliance check). Replacement happens via a PR to this repo (or, in the multi-repo future, via an `@uses` reference to a pinned reusable workflow in the customer's own repo).

### 5.11 `notify.yaml`

**Purpose.** Optional SNS/Slack echo of workflow completion. AFT equivalent: `aft-notifications` + `aft-failure-notifications` SNS topics (`aft-analysis.md` §4.3).

**Triggers.**
```yaml
on:
  workflow_run:
    workflows: [provision-account.yaml, destroy-account.yaml, customize-fleet.yaml, drift-detection.yaml]
    types: [completed]
```

**Jobs.**
- Resolve workflow status.
- Publish to SNS if `vars.SNS_NOTIFICATIONS_TOPIC_ARN` is set.
- Publish to Slack webhook if `secrets.SLACK_WEBHOOK_URL` is set.
- No-op otherwise.

### 5.12 `ct-lifecycle-event.yaml`

**Purpose.** Receive Control Tower lifecycle events (`CreateManagedAccount`, `UpdateManagedAccount`, `RegisterOrganizationalUnit`) forwarded from the `controltower-event-bridge` component (`module-inventory.md` row 8, §4.1) via EventBridge → API destination → GitHub `repository_dispatch`. AFT equivalent: the `aft_controltower_events` DDB table + stream-triggered Lambda (`aft-analysis.md` §4.5).

**Triggers.**
```yaml
on:
  repository_dispatch:
    types:
      - ct-create-managed-account
      - ct-update-managed-account
      - ct-register-organizational-unit
```

**Inputs (from `client_payload`).** `event_name`, `account_id`, `account_email`, `ou_name`, `ou_id`, `provisioned_product_id`, `service_event_details` (full CT event body preserved verbatim for the audit trail).

**Jobs.**

| Job | Purpose |
|---|---|
| `archive` | Write the full `client_payload` to S3 (`s3://atmos-aft-ct-events-<aft-mgmt>/<yyyy>/<mm>/<dd>/<event_id>.json`) for long-retention replay. Replaces the `aft_controltower_events` DDB table's audit role. |
| `classify` | Route by `event_name`. `CreateManagedAccount` → correlate with provisioning in flight. `UpdateManagedAccount` → may require customisation resync. `RegisterOrganizationalUnit` → archive only. |
| `correlate` | Look up SSM at `/aft/account/<account_id>/status`. If absent, this is a CT-initiated account not yet tracked in our repo — open a `ct-unmanaged-account` GH issue. If `status=provisioning`, update to `status=ct-confirmed`. If `status=closing`, flag as unexpected. |
| `fanout` | If `classify` chose `resync`, dispatch `customize-fleet.yaml` with `scope=stack:<resolved>`. If CT emitted a managed account our repo hasn't seen, fanout is *not* called — onboarding is operator-triggered via `import-existing-account.yaml`. |

**Concurrency.** `ct-event-${{ github.event.client_payload.event_id }}`. CT emits events with an `event_id` UUID; duplicates (EventBridge at-least-once delivery) are coalesced by this group. `cancel-in-progress: false`.

**Auth.** OIDC → `AtmosCentralDeploymentRole`. The workflow does no Terraform; it reads SSM and optionally dispatches other workflows.

**Permissions.**
```yaml
permissions:
  contents: read
  id-token: write
  actions: write      # to dispatch customize-fleet.yaml
  issues: write       # to open ct-unmanaged-account issues
```

**Auth mechanism for the inbound side (EventBridge → repository_dispatch).** See §10.1 "CT-lifecycle inbound credentials" — two supported modes (GitHub App default, fine-grained PAT fallback), selectable via the `controltower-event-bridge` component's `vars.github_auth_mode`.

**Delivery durability for long rotator outages.** The EventBridge API destination's built-in retry queue caps at 24h / 185 attempts, which is **not** sufficient for a Fri-evening-to-Mon-morning rotator outage. The `controltower-event-bridge` component therefore attaches an SQS DLQ to the API destination target with:

- 14-day message retention (`message_retention_seconds: 1209600`)
- CloudWatch alarm on `ApproximateNumberOfMessagesVisible > 0` → SNS to platform-ops
- IAM: EventBridge role gets `sqs:SendMessage` on DLQ ARN only
- Replay via a single-loop runbook operation (`aws events put-events` per DLQ message, or an operator-triggered Lambda if replay becomes frequent)

Rationale (aws-architect, [`archive/review.md`](archive/review.md) §6 decisions log): S3 archive was rejected because building replay tooling is a new burden; SQS DLQ gives 14-day cover with single-loop replay semantics that Ops already know from other API-destination integrations.

---

## 6. Reusable workflows (`workflow_call`)

Every reusable workflow is self-contained: accepts inputs, consumes a pinned composite action set, produces explicit outputs. Reusables never call entry-point workflows.

### 6.1 `_atmos-plan.yaml`

**Purpose.** Plan one Atmos component instance. Upload planfile.

**Inputs.**
```yaml
stack:            { required: true, type: string }
component:        { required: true, type: string }
upload_planfile:  { required: false, type: boolean, default: true }
plan_store:       { required: false, type: string, default: 's3' }
```

**Outputs.**
```yaml
has_changes:      { description: 'true if plan has changes' }
has_destructions: { description: 'true if plan would destroy' }
planfile_key:     { description: 'S3 key or artifact name' }
```

**Secrets.**
```yaml
AWS_ACCESS_KEY_ID:     { required: false }
AWS_SECRET_ACCESS_KEY: { required: false }
```

**Steps.**
1. `.github/actions/setup-atmos`
2. `.github/actions/configure-aws` (mode from env)
3. `atmos terraform plan ${{ inputs.component }} -s ${{ inputs.stack }} --ci`
4. If `upload_planfile`: `atmos terraform planfile upload ${{ inputs.component }} -s ${{ inputs.stack }}`
5. Parse `$GITHUB_OUTPUT` for `has_changes`, `has_destructions`.

**Why reusable.** Six entry-point workflows need "plan one instance" semantics. Centralising the planfile store logic means we can migrate from S3 to GH Artifacts by changing one file.

### 6.2 `_atmos-apply.yaml`

**Purpose.** Apply one Atmos component instance. Verifies a stored plan before applying when `require_stored_plan: true`.

**Inputs.**
```yaml
stack:               { required: true, type: string }
component:           { required: true, type: string }
require_stored_plan: { required: false, type: boolean, default: false }
planfile_key:        { required: false, type: string }
retry_attempts:      { required: false, type: number, default: 1 }
retry_delay_seconds: { required: false, type: number, default: 60 }
```

**Outputs.**
```yaml
apply_status:     { description: 'succeeded|failed' }
resource_changes: { description: 'JSON summary of applied changes' }
```

**Steps.** `setup-atmos` → `configure-aws` → optional `atmos terraform planfile download` → `atmos terraform deploy ${component} -s ${stack} --ci` with retry on eventual-consistency errors (matches AFT's `create_role` retry — `aft-analysis.md` §2 phase D). Publishes outputs to store.

### 6.3 `_atmos-destroy.yaml`

**Purpose.** Destroy one Atmos component instance. Requires explicit `confirm: true` input to prevent accidental invocation.

**Inputs.**
```yaml
stack:     { required: true, type: string }
component: { required: true, type: string }
confirm:   { required: true, type: boolean }
```

**Steps.** Guards `confirm == true` → `setup-atmos` → `configure-aws` → `atmos terraform destroy ${component} -s ${stack} --ci -auto-approve`.

### 6.4 `_atmos-validate.yaml`

**Purpose.** Run `atmos validate stacks` + OPA policies. Called by `pr.yaml`.

**Steps.** `setup-atmos` → `atmos validate stacks` → `opa eval -b .github/policies -i <(atmos describe stacks --format json)`.

### 6.5 `_customize-global.yaml` / `_customize-account.yaml`

**Purpose.** Replace AFT's `aft-global-customizations-terraform` and `aft-account-customizations-terraform` CodeBuild projects (`aft-analysis.md` §3.1 projects 3 and 4).

**Inputs.**
```yaml
target_stacks:           { required: true,  type: string }   # JSON array, chunk of <= 200
customization_name:      { required: false, type: string }   # only for _customize-account
customizations_source_ref: { required: false, type: string, default: 'HEAD' }
```

**Strategy.**
```yaml
strategy:
  matrix:
    stack: ${{ fromJson(inputs.target_stacks) }}
  fail-fast: false
  max-parallel: 20
```

**Steps per matrix entry.**
1. `setup-atmos`, `configure-aws`
2. Run pre-hook script (replaces `pre-api-helpers.sh` from AFT's buildspec — `aft-analysis.md` §3.1).
3. `_atmos-apply.yaml` call with `component = customizations/global` or `customizations/${customization_name}`.
4. Run post-hook script (replaces `post-api-helpers.sh`).
5. `publish-status` composite: write `/aft/account/<n>/status = customized`.

### 6.6 `_feature-options.yaml`

**Purpose.** Replace AFT's `aft-feature-options` SFN (`aft-analysis.md` §4.4 item 4). Three inline applies, all gated by stack vars.

**Inputs.**
```yaml
stack: { required: true, type: string }
```

**Jobs (sequential, conditional on stack vars).**
- `delete-default-vpcs` if `vars.feature_options.delete_default_vpcs == true`
- `enroll-enterprise-support` if `vars.feature_options.enroll_support == true`
- `enable-cloudtrail-org-logging` if `vars.feature_options.enable_cloudtrail == true`

Each job is a `_atmos-apply.yaml` call.

### 6.7 `_matrix-chunk.yaml`

**Purpose.** Split a target list > 200 into child `workflow_call`s. Solves the GHA 256-job matrix ceiling (`mapping.md` §9 item 4).

**Inputs.**
```yaml
targets:         { required: true, type: string }       # JSON array
chunk_size:      { required: false, type: number, default: 200 }
downstream_workflow: { required: true, type: string }   # 'customize-global' | 'customize-account'
```

**Behaviour.** Partitions `targets` into N chunks of `chunk_size`. Emits N outputs `chunk_0_targets`, `chunk_1_targets`, …. The caller (e.g., `customize-fleet.yaml`) iterates outputs with a second-level matrix over chunk indices, calling `_customize-global.yaml` with `target_stacks = <one chunk>`.

### 6.8 `_post-provision-hook.yaml`

**Purpose.** Thin wrapper around `custom-provisioning-hook.yaml` that adds structured inputs and a standard timeout. Call site: job 8 of `provision-account.yaml`.

### 6.9 `_bootstrap-target.yaml`

**Purpose.** Apply one Atmos component in a newly vended account **before** `AtmosDeploymentRole` exists. Uses the `bootstrap` Atmos identity which resolves to `AWSControlTowerExecution` in the target (or `OrganizationAccountAccessRole` for CT-managed core accounts — see §4.5).

**When called.**
- `provision-account.yaml` jobs 3 (`tfstate-backend`) and 4 (`iam-deployment-roles/target`) — stamping the target account.
- `bootstrap.yaml` when it stamps `AtmosDeploymentRole` into the four CT-managed core accounts (CT-mgmt, AFT-mgmt, audit, log-archive).

AFT equivalent: the path used by the `create_role` Lambda in `aft-account-provisioning-framework` SFN (`aft-analysis.md` §2 phase D), which assumes `AWSControlTowerExecution` in the new account via the provider alias chain in `reference/aft/providers.tf:1-57` — the single runtime use of `AWSControlTowerExecution` in AFT.

**Inputs.**
```yaml
stack:               { required: true,  type: string }
component:           { required: true,  type: string }
fallback_role:       { required: false, type: string, default: 'AWSControlTowerExecution' }
retry_attempts:      { required: false, type: number, default: 5 }
retry_delay_seconds: { required: false, type: number, default: 60 }
```

`fallback_role` defaults to `AWSControlTowerExecution` (CT-vended accounts) and is only consulted when the resolved stack does not set `vars.bootstrap_role` (per `stacks/catalog/account-classes/*.yaml` — CT-core classes pin `OrganizationAccountAccessRole`). The effective role name is composed with `vars.account_id` into `target_role_arn = arn:aws:iam::<account_id>:role/<role>` and passed to `configure-aws`, which exports it as `TF_VAR_target_role_arn` for the component's `provider "aws" { dynamic "assume_role" { ... } }` block.

**Outputs.**
```yaml
apply_status:     { description: 'succeeded|failed' }
resource_changes: { description: 'JSON summary of applied changes' }
```

**Steps.**
1. `setup-atmos` (§7.1).
2. `resolve-stack` (§7.3) to emit `account_id`, `region`, and `bootstrap_role`.
3. Compose bootstrap ARN: `target_role_arn = arn:aws:iam::${account_id}:role/${bootstrap_role:-${fallback_role}}`, gated by an allowlist of `AWSControlTowerExecution` | `OrganizationAccountAccessRole`.
4. `configure-aws` (§7.2) with `central_role_arn`, `target_role_arn` (from step 3), and `identity: bootstrap` (session pinned to `atmos-bootstrap-${{ inputs.stack }}-${{ github.run_id }}`). `configure-aws` exports `TF_VAR_target_role_arn` so the component's provider `dynamic "assume_role"` block resolves to the bootstrap role.
5. `atmos terraform deploy ${{ inputs.component }} -s ${{ inputs.stack }} --ci` with the same retry pattern as `_atmos-apply.yaml` (handles IAM eventual consistency — matches AFT's `create_role` 5×/60s/backoff-1.5x retry).
6. Publish outputs to SSM via `store-outputs` hook (for `tfstate-backend`: the bucket name for downstream components to read).

**Why separate from `_atmos-apply.yaml`.** Keeping the bootstrap identity out of `_atmos-apply.yaml` means the 90%+ of apply calls that use the normal chain cannot accidentally pick up the elevated `AWSControlTowerExecution` role. One env var (`ATMOS_AUTH_IDENTITY`) set in one reusable is the enforcement surface; a grep for `_bootstrap-target.yaml` call sites enumerates every place the elevated chain is used.

### 6.10 `_apply-security-service.yaml`

**Purpose.** Enforce the three-phase deployment mandated by `module-inventory.md` §5.5 for GuardDuty, Security Hub, and Inspector2. Each of these services has an AWS API coupling where phase N+1 fails unless phase N has converged *and* IAM has propagated the delegated-admin role binding. A matrix strategy with any `max-parallel > 1` over the three components can race the phases: e.g., `guardduty-delegated-admin` applied before `aws_guardduty_organization_admin_account` finishes propagating yields `BadRequestException: The request is rejected because the caller is not registered as a delegated administrator`. This workflow serialises the three phases with hard `needs:` edges and adds a propagation wait between phase 1 and phase 2.

**Inputs.**
```yaml
service:                 { required: true,  type: string }   # 'guardduty' | 'security-hub' | 'inspector2'
mgmt_stack:              { required: true,  type: string }   # stack instance for the org-root apply (phase 1)
audit_stack:             { required: true,  type: string }   # stack instance for the delegated-admin apply (phase 2)
target_stacks:           { required: false, type: string }   # JSON array of stacks needing phase-3 member overrides
propagation_wait_seconds:{ required: false, type: number, default: 30 }
skip_if_already_applied: { required: false, type: boolean, default: false }
```

**Phase ordering (hard `needs:` chain, no parallelism between phases).**

```
phase-1-delegate           ->  _atmos-apply.yaml with component=<service>-root,
        |                      stack=${mgmt_stack}
        |                      (registers delegated admin at the org root)
        v
propagate                  ->  sleep ${propagation_wait_seconds}s + IAM probe:
        |                      aws <service> list-organization-admin-accounts --query
        |                      'AdminAccounts[?AdminAccountId==`<audit_account_id>`]'
        |                      polled every 15s until non-empty or 5-min timeout
        v
phase-2-org-config         ->  _atmos-apply.yaml with component=<service>-delegated-admin,
        |                      stack=${audit_stack}
        |                      (org-wide detector/hub config, auto-enable members)
        v
phase-3-member-settings    ->  matrix of _atmos-apply.yaml over target_stacks
                               with component=<service>-member-settings
                               (max-parallel: 20 — member-level is account-local, safe to
                               fan out BECAUSE phases 1 and 2 are guaranteed complete by needs:)
```

`phase-3-member-settings` is the **only** stage that fans out in a matrix, and only after phases 1 and 2 have succeeded. This is the invariant that a naive `max-parallel: 4` matrix over `(root, delegated-admin, member-settings)` would violate.

**`skip_if_already_applied` mode.** For per-account provisioning (called from `provision-account.yaml` §5.3 job 7), phases 1 and 2 are **already** applied by the bootstrap + fleet baseline runs — re-applying them per new account is unnecessary and thrashes the org-level resources. When `skip_if_already_applied=true`, the workflow probes for `aws_<service>_organization_admin_account` and a non-empty delegated-admin binding; if both exist, it short-circuits to phase 3 only. This keeps the invariant (phases 1 and 2 must be applied before 3) while avoiding wasteful no-op applies.

**First-run bootstrap ordering.** Phase 1 requires that the audit/security account itself exists and is registered as a Control Tower core account. The bootstrap ordering is therefore:

1. CT landing zone deployed out-of-band (operator, pre-Atmos) — produces the audit and log-archive accounts as CT core accounts.
2. `bootstrap.yaml` (§5.8) runs `github-oidc-provider` + `iam-deployment-roles/central` + `tfstate-backend` in the aft-mgmt account.
3. `bootstrap.yaml` then runs `_apply-security-service.yaml` once for each of `guardduty`, `security-hub`, `inspector2` with `skip_if_already_applied=false` and an **empty** `target_stacks` (phases 1 and 2 only; no members to enrol yet). See §5.8 bootstrap step 5.
4. From this point on, `provision-account.yaml` vends new members and invokes `_apply-security-service.yaml` with `skip_if_already_applied=true` per new stack, reaching only phase 3.
5. Changes to phase-1 or phase-2 stacks (e.g., rotating the delegated-admin account) are picked up by `customize-fleet.yaml` under its regular `describe affected` path and call `_apply-security-service.yaml` with `skip_if_already_applied=false` to re-run phases 1 and 2 explicitly.

**Error recovery.** If phase 2 fails after phase 1 succeeded, the partial state is: delegated-admin registered but org config not applied. Re-running the workflow from scratch is safe — phase 1 is idempotent and phase 2 picks up where it left off. If phase 1 itself fails mid-apply (rare; single API call), state drift is recoverable via `terraform taint` on `aws_<service>_organization_admin_account` and re-running.

**Empirical tuning (post-launch).** Default `propagation_wait_seconds=30` is sized against typical IAM propagation latency; `list-organization-admin-accounts` can occasionally return "present" before the audit-account SLR is fully usable cross-account (aws-architect review, [`archive/review.md`](archive/review.md) §6 decisions log). The AWS Terraform provider's built-in service-API retries absorb this, and phase 2 is idempotent on re-run. Mitigation if ops dashboards show repeated phase-2 retries: bump `propagation_wait_seconds` default to 60–90 via the workflow input. No design change required; this is an empirical tunable, like the `max-parallel` values in §8.3.

---

## 7. Composite actions

Composite actions factor out step sequences used in three or more workflows. Each is one directory under `.github/actions/`.

### 7.1 `setup-atmos`

**Steps.**
1. `actions/checkout@v4`
2. `hashicorp/setup-terraform@v3` with version from `atmos.yaml` `components.terraform.version` (parsed via `yq`).
3. `cloudposse/github-action-setup-atmos@v2` with version from same file.
4. Cache `~/.atmos` and `components/terraform/**/.terraform` keyed by `${{ hashFiles('vendor.yaml', 'atmos.yaml') }}`.

### 7.2 `configure-aws`

See §4.2 sketch. Inputs: `mode`, `central_role_arn`, `target_role_arn`, `region`, `role_session_name`. Outputs: `account_id` (from `sts:GetCallerIdentity`).

### 7.3 `resolve-stack`

**Purpose.** Resolve a stack name to `account_id` (via `!store core-ssm account-provisioning account_id`) and the full auth context. Called before any `configure-aws` step that needs a cross-account hop.

**Outputs.** `account_id`, `region`, `target_role_arn`, `stack_name`.

### 7.4 `publish-status`

**Purpose.** Write `/aft/account/<n>/status` to SSM via the `core-ssm` store. Used at end of each provisioning phase.

**Inputs.** `status` (`provisioning` | `baseline-deployed` | `customized` | `drift` | `failed`), `stack`.

### 7.5 `post-plan-summary`

**Purpose.** Aggregate planfile diffs into `$GITHUB_STEP_SUMMARY` and PR comment. Uses `cloudposse/github-action-terraform-plan-storage@v1` for cross-workflow plan persistence.

### 7.6 `install-gha-cli-deps`

Minor. Installs `jq`, `yq`, `gh` at pinned versions.

---

## 8. Concurrency and fan-out

### 8.1 Concurrency groups

Every workflow declares a `concurrency` block. The matrix below enumerates them:

| Workflow | Group | `cancel-in-progress` | Rationale |
|---|---|---|---|
| `pr.yaml` | `pr-<PR#>` | `true` | Latest PR state wins; cheap to re-run. |
| `push-main.yaml` | `push-main` | `false` | Serial on merge order; never cancel. |
| `provision-account.yaml` | `provision-<stack>` | `false` | One per-stack provision at a time; never cancel mid-flight. |
| `provision-account.yaml` job `account-provisioning` only | `ct-provisioning` (global) | `false` | Serialises Service Catalog calls against CT Account Factory portfolio — CT itself serialises vendings anyway. |
| `customize-fleet.yaml` | `customize-fleet-<scope>` | `false` | Different scopes can overlap; same scope cannot. |
| `customize-fleet.yaml` + `provision-account.yaml` mutual exclusion | via `customize-fleet-global` on customize-fleet + a tag-wait in provision | `false` | Prevents customize-fleet running while a new account's provision is mid-flight (would race on `customizations/global` for a not-yet-fully-baselined account). |
| `drift-detection.yaml` | `drift-detection` | `true` | New drift run supersedes stale. |
| `import-existing-account.yaml` | `import-<stack>` | `false` | Serial per stack. |
| `destroy-account.yaml` | `destroy-<stack>` | `false` | Serial per stack; never cancel. |
| `bootstrap.yaml` | `bootstrap` | `false` | Global singleton. |
| `vendor-refresh.yaml` | `vendor-refresh` | `true` | New refresh supersedes stale PR branch. |
| `notify.yaml` | none | — | Best-effort; duplicates are fine. |

Global `ct-provisioning` group maps directly to AFT's FIFO SQS (`aft-account-request.fifo` + DLQ, `aft-analysis.md` §4.2) — the whole reason AFT serialised provisioning was to keep Service Catalog calls ordered.

### 8.2 Matrix fan-out strategy

Three fan-out flavours:

#### 8.2.1 Inline matrix (< 200 instances)

Typical case. `strategy.matrix.stack` populated directly from `atmos list instances --format matrix -o $GITHUB_OUTPUT`. `max-parallel` limits runner consumption.

```yaml
strategy:
  matrix:
    include: ${{ fromJson(needs.affected.outputs.matrix) }}
  fail-fast: false
  max-parallel: 20
```

#### 8.2.2 Chunked matrix (>= 200 instances)

The `_matrix-chunk.yaml` reusable splits the input into chunks of 200. The parent workflow then does:

```yaml
jobs:
  chunk:
    uses: ./.github/workflows/reusable/_matrix-chunk.yaml
    with:
      targets: ${{ needs.resolve-targets.outputs.target_list }}
      chunk_size: 200

  customize-chunks:
    needs: chunk
    strategy:
      matrix:
        chunk_index: ${{ fromJson(needs.chunk.outputs.chunk_indices) }}
      fail-fast: false
      max-parallel: 2
    uses: ./.github/workflows/reusable/_customize-global.yaml
    with:
      target_stacks: ${{ fromJson(needs.chunk.outputs[format('chunk_{0}', matrix.chunk_index)]) }}
```

This is the direct analogue of AFT's `aft-invoke-customizations` SFN's Distributed Map with S3 iterator (`aft-analysis.md` §2 phase E step 10) — the key idea is "stage the target list externally, dispatch chunks".

#### 8.2.3 Cross-workflow dispatch (> 2000 instances)

At true fleet scale (> 10 chunks of 200) a single parent workflow cannot enumerate without hitting GHA's 1000-job-per-workflow cap. In that case, the parent workflow uses `gh workflow run` to dispatch independent `customize-fleet.yaml --scope chunk:<N>` runs, each with its own concurrency group. Not required at current fleet scale (< 100 accounts); the code path is reserved.

### 8.3 Matrix parallelism tuning

Default `max-parallel` per fan-out:

| Fan-out | `max-parallel` | Rationale |
|---|---|---|
| `pr.yaml` plan | 10 | PR feedback needs to be quick; 10 concurrent plans is bearable. |
| `provision-account.yaml` job 7 (baseline-security across services) | **1** | **Must be 1.** Sub-stages 7a/7b/7c/7d are sequential, not a matrix. GuardDuty, Security Hub, and Inspector2 each have three-phase API coupling (`module-inventory.md` §5.5); `_apply-security-service.yaml` (§6.10) enforces the intra-service `needs:` chain. Cross-service serialisation (7b → 7c → 7d) is additionally required because all three services share the same delegated-admin account; simultaneous `aws_*_organization_admin_account` API calls from two services can leave the audit account's IAM policy in an interleaved state (observed in integration testing of AFT's reference implementation, which similarly runs these serially). |
| `_apply-security-service.yaml` phase-3 member-settings | 20 | Phase 3 is account-local and only runs after phases 1+2 have converged; safe to fan out. |
| `customize-fleet.yaml` customize-* | 20 | Customisations are account-local; high parallelism OK. |
| `drift-detection.yaml` plan | 20 | Read-only, high parallelism fine. |
| `destroy-account.yaml` any | 1 | Always serial. |

Tunable via GHA repo-level variables `AFT_PROVISION_PARALLELISM`, `AFT_CUSTOMIZE_PARALLELISM`, `AFT_DRIFT_PARALLELISM`, `AFT_SECURITY_PHASE3_PARALLELISM`. Defaults above.

**Not tunable:** job 7 sub-stage ordering and the intra-service three-phase chain. These are correctness invariants, not performance knobs; they do not expose a repo-var override. A future phase may widen job 7 to run 7a/7b/7c/7d in parallel after empirical validation that the three services do not contend on the delegated-admin account's IAM; for phase 1 this is a firm serial.

---

## 9. State and artifact handoff across workflows

Three mechanisms, used in the following order of preference:

### 9.1 Atmos stores (SSM)

The primary cross-workflow data plane. Every component that produces data another workflow needs declares a `hooks.store-outputs` block (`atmos-model.md` §8.3).

Canonical store namespaces for this repo:

```yaml
stores:
  core-ssm:
    type: aws-ssm-parameter-store
    options:
      region: ${SHARED_SERVICES_REGION}
      prefix: /aft/

  core-ssm-status:
    type: aws-ssm-parameter-store
    options:
      region: ${SHARED_SERVICES_REGION}
      prefix: /aft/account/
```

Written by `store-outputs` hooks and by the `publish-status` composite action. Read by `!store`. SSM parameter paths standardised:

| Path | Writer | Reader |
|---|---|---|
| `/aft/config/terraform/version` | `atmos.yaml` → SSM (bootstrap) | every workflow via `setup-atmos` |
| `/aft/account/<name>/account-id` | `account-provisioning` store-outputs | every downstream component |
| `/aft/account/<name>/region` | `account-provisioning` store-outputs | every downstream component |
| `/aft/account/<name>/status` | `publish-status` composite | operator dashboards, `customize-fleet` filter |
| `/aft/account/<name>/customization-name` | stack var → SSM on first apply | `customize-account.yaml` |
| `/aft/shared/deployment-role-arn` | `iam-deployment-roles/central` store-outputs | `configure-aws` composite |

### 9.2 GitHub Actions artifacts

Used only for ephemeral data scoped to one workflow run — plan files, log tarballs, debug dumps. Not for cross-workflow handoff (GH artifacts don't cross workflow boundaries reliably).

### 9.3 Planfile store (S3 via `atmos terraform planfile`)

For cross-workflow plan persistence (PR plan → merged-push apply), use Atmos' native planfile store (`atmos-model.md` §6 under "Plan / apply"):

```yaml
# atmos.yaml (conceptual)
components:
  terraform:
    plan_storage:
      type: s3
      bucket: atmos-aft-planfiles-${shared_services_account_id}
      prefix: plans/
      region: ${SHARED_SERVICES_REGION}
```

Upload from `pr.yaml` job `plan` via `atmos terraform planfile upload`. Download in a later workflow via `atmos terraform planfile download`. Key format: `plans/<pr-number>/<sha>/<stack>/<component>.tfplan`.

**Not used for provision-account → customize flow.** That handoff is via SSM (account_id), not planfiles — the two workflows plan against fresh state.

### 9.4 What explicitly does not cross workflows

- Runner working directory state.
- Terraform `.terraform/` caches — re-initialised each run.
- AWS credentials — every job calls `configure-aws` fresh.

These constraints mean every workflow is self-contained at the runner level; any required context comes from Git (checkout), SSM (store), or artifacts (planfile).

---

## 10. Secrets and environments

### 10.1 Secret storage

Three tiers:

**Repository secrets** — things every environment shares.
- `GITHUB_TOKEN` — auto-provided.
- `SLACK_WEBHOOK_URL` — optional notifier.
- `ATMOS_LICENSE_KEY` — Atmos Pro if used; omit otherwise.

**Environment secrets** — tier-specific.
- `AFT_BOOTSTRAP_ACCESS_KEY_ID` / `AFT_BOOTSTRAP_SECRET_ACCESS_KEY` — only in `bootstrap` and `test` environments; rotated after use.
- `TERRAFORM_CLOUD_TOKEN` — only in environments with `terraform_distribution: tfc`; empty otherwise.
- `SERVICENOW_TOKEN` — only if `custom-provisioning-hook` uses ServiceNow.

**Environment variables (`vars:`)** — non-secret config.
- `ATMOS_CENTRAL_ROLE_ARN` — per environment.
- `AFT_AUTH_MODE` — `oidc` or `access_key` per environment.
- `SHARED_SERVICES_REGION`, `SHARED_SERVICES_ACCOUNT_ID`.
- `AFT_PROVISION_PARALLELISM`, `AFT_CUSTOMIZE_PARALLELISM`, `AFT_DRIFT_PARALLELISM`.

**CT-lifecycle inbound credentials** — the only secret that lives outside GitHub Actions. EventBridge (in the CT management account) needs to call `POST https://api.github.com/repos/<org>/<repo>/dispatches`. This requires a GitHub credential readable by the EventBridge connection. Two modes, default-to-safest per the OIDC-vs-access-key posture:

**Mode A: GitHub App (default).** A dedicated GitHub App (`atmos-aft-ct-dispatch`) is installed on this single repo with the narrowest possible scope: one permission, `Actions: write` (the GitHub fine-grained permission required for `POST /repos/:o/:r/dispatches`; GitHub does not offer per-endpoint scoping, but one permission + one repo install is the minimum blast radius available). The App's private key is stored in AWS Secrets Manager (`atmos-aft/ct-dispatch/github-app-private-key` in the CT management account). A bespoke Lambda rotator — lives alongside the `controltower-event-bridge` component — exchanges the private key for a ~1-hour installation token every **30 minutes** and writes the token to a second secret (`atmos-aft/ct-dispatch/github-installation-token`) that the EventBridge connection reads. Rotation is automatic; the long-lived secret is the App private key (rotated per org policy, typically annually).

Rotator kept as a bespoke Lambda (not wired into the Secrets Manager rotation framework). The SMR four-step `RotateSecret` protocol is designed for DB-credential atomic swaps; our "mint short-lived token from long-lived PEM" case is simpler and does not need the protocol ceremony. Out-of-the-box SMR alerting is reproduced with two CloudWatch alarms on the bespoke Lambda: (a) error-count > 0 over 1 datapoint, (b) downstream `GetSecretValue` `LastChangedDate` age on `github-installation-token` > 35 min.

Rotator Lambda IAM is scoped to the narrowest usable surface — no wildcards:
```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue"],
      "Resource": "arn:aws:secretsmanager:<region>:<ct-mgmt>:secret:atmos-aft/ct-dispatch/github-app-private-key-*"
    },
    {
      "Effect": "Allow",
      "Action": ["secretsmanager:PutSecretValue"],
      "Resource": "arn:aws:secretsmanager:<region>:<ct-mgmt>:secret:atmos-aft/ct-dispatch/github-installation-token-*"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt"],
      "Resource": "arn:aws:kms:<region>:<ct-mgmt>:key/<pem-secret-cmk-id>"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:GenerateDataKey"],
      "Resource": "arn:aws:kms:<region>:<ct-mgmt>:key/<token-secret-cmk-id>"
    }
  ]
}
```
The two secrets use distinct CMKs so the rotator cannot read the token secret (principle of least privilege: the rotator writes but never reads its own output).

Why default: no long-lived bearer token in AWS, tokens are per-installation (revocable without rotating other consumers), auditable via GitHub App audit log, fine-grained permission surface (one permission, one repo).

**Mode B: fine-grained PAT (fallback).** A fine-grained PAT with `Actions: write` on the single repo, stored as `atmos-aft/ct-dispatch/github-pat` in Secrets Manager. Simpler to bootstrap (no App to register, no rotator Lambda), at the cost of a long-lived bearer token requiring manual rotation (recommend 90 days). Rejected as default because the rotation is operator toil and the token scope cannot be narrowed below "repo-level Actions write".

**Mode selection.** `controltower-event-bridge` component variable:
```yaml
vars:
  github_auth_mode: app    # or 'pat'
  github_app_id: "<numeric app id>"              # mode A only
  github_app_installation_id: "<numeric inst id>" # mode A only
  # secret ARN is derived from the mode
```

**Secrets Manager resources (created by `controltower-event-bridge`).**

| Secret name | Mode | Purpose | Rotation |
|---|---|---|---|
| `atmos-aft/ct-dispatch/github-app-private-key` | A | GitHub App PEM. Source of truth. | Manual/annual. Rotator Lambda reads this to mint installation tokens. |
| `atmos-aft/ct-dispatch/github-installation-token` | A | Short-lived installation token (~1h). Read by EventBridge connection. | Automatic every 30 min by rotator Lambda. |
| `atmos-aft/ct-dispatch/github-pat` | B | Fine-grained PAT. Read by EventBridge connection. | Manual every 90 days. |

EventBridge connection uses `AuthorizationType=API_KEY` with header `Authorization: Bearer <secret value>` in both modes; the only difference is which secret feeds the connection and whether a rotator Lambda is deployed. The `controltower-event-bridge` component picks this based on `github_auth_mode` and wires the IAM permissions for the connection's role to read only the selected secret.

### 10.2 Environments and required reviewers

Five GHA environments:

| Environment | Scope | Required reviewers | Wait timer | Deployment branches |
|---|---|---|---|---|
| `pr` | PR plans, validations | none | none | any |
| `aft-mgmt` | All writes to the atmos-aft management account (bootstrap, account-provisioning, customizations orchestration) | 1 | none | `main` |
| `prod` | All writes to vended accounts classified as production | 2 | 10 minutes | `main` |
| `non-prod` | All writes to vended accounts classified as dev/staging | 1 | none | `main` |
| `destroy` | `destroy-account.yaml` only | 2 | 30 minutes | `main` |
| `bootstrap` | `bootstrap.yaml` only | 2 | none | `main` |

Stack-to-environment routing is computed by a matrix expression based on `vars.stage`:

```yaml
jobs:
  deploy:
    environment: ${{ inputs.stack == 'aft-mgmt-*' && 'aft-mgmt' || (contains(inputs.stack, '-prod') && 'prod' || 'non-prod') }}
```

Encoded in a composite action `resolve-environment` so the logic stays in one place.

### 10.3 Branch protection

`main` branch rules:
- Require PR with 1 approval (2 for changes under `components/terraform/account-provisioning/` or `.github/workflows/`).
- Require status checks from `pr.yaml` to pass.
- Restrict pushes to `main` to the `automation` bot or direct-merge.
- Disallow force-pushes.

CODEOWNERS enforces that `.github/workflows/reusable/_*.yaml` and `.github/policies/*` require platform-team review.

### 10.4 Secret rotation

| Secret | Rotation cadence | Procedure |
|---|---|---|
| `AFT_BOOTSTRAP_ACCESS_KEY_ID` | After bootstrap complete; then quarterly if retained | `aws iam create-access-key` for the bootstrap user, update the `AFT_BOOTSTRAP_ACCESS_KEY_ID` / `AFT_BOOTSTRAP_SECRET_ACCESS_KEY` repo secrets, then `aws iam delete-access-key` on the previous key. A helper script is not yet shipped. |
| `TERRAFORM_CLOUD_TOKEN` | 90 days | HCP UI + update environment secret. |
| `atmos-aft/ct-dispatch/github-app-private-key` (mode A) | Annual | GitHub App settings → regenerate key → write to Secrets Manager. Rotator Lambda picks up the new key on next invocation (no EventBridge downtime). |
| `atmos-aft/ct-dispatch/github-installation-token` (mode A) | Automatic every 30 min by rotator Lambda | No operator action. Two CloudWatch alarms: rotator error-count > 0, and `github-installation-token` `LastChangedDate` age > 35 min (either triggers SNS to platform-ops). |
| `atmos-aft/ct-dispatch/github-pat` (mode B) | 90 days | GitHub fine-grained PAT UI → generate new token → write to Secrets Manager → delete old version. EventBridge connection automatically picks up `AWSCURRENT`. |
| `SERVICENOW_TOKEN` | 30 days (or per customer policy) | Customer procedure. |
| `SLACK_WEBHOOK_URL` | On compromise only | Revoke + regenerate in Slack admin. |

OIDC has no secret to rotate; the trust relationship is the only mutable piece and lives in Terraform.

---

## 11. Explicit AFT CodeBuild/CodePipeline coverage matrix

Every AFT CodeBuild project and CodePipeline enumerated in `aft-analysis.md` §3, with its GHA replacement.

### 11.1 CodeBuild projects

| AFT CodeBuild | `aft-analysis.md` ref | GHA replacement | Trigger | Inputs | Outputs |
|---|---|---|---|---|---|
| `ct-aft-account-request` | §3.1 item 1, §6.1 | **Deleted.** Stack YAML in this repo is the request; PR workflow validates. | `pull_request`, `push` | PR event | Plan comment, validate result |
| `ct-aft-account-provisioning-customizations` | §3.1 item 2, §6.2 | `custom-provisioning-hook.yaml` reusable (default no-op) | `workflow_call` from `provision-account` job 8 | `stack`, `account_id` | Hook success/failure |
| `aft-global-customizations-terraform` | §3.1 item 3, §6.3 | `_customize-global.yaml` reusable | `workflow_call` from `provision-account` job 9 and `customize-fleet.yaml` | `target_stacks`, `customization_name` | Apply status per stack |
| `aft-account-customizations-terraform` | §3.1 item 4, §6.4 | `_customize-account.yaml` reusable | `workflow_call` from `provision-account` job 10 and `customize-fleet.yaml` | `target_stacks`, `customization_name` | Apply status per stack |
| `aft-create-pipeline` | §3.1 item 5 | **Deleted.** No per-account pipeline to materialise. | — | — | — |
| `aft-lambda-layer` build-time | §1.9 | **Deleted.** No Lambdas. | — | — | — |

### 11.2 CodePipelines

| AFT CodePipeline | `aft-analysis.md` ref | GHA replacement | Trigger | Inputs | Outputs |
|---|---|---|---|---|---|
| `ct-aft-account-request` | §3.2 pipeline 1 | `pr.yaml` + `push-main.yaml` | `pull_request`, `push` | PR/push event | Plan comment, route to provision/customize/destroy |
| `ct-aft-account-provisioning-customizations` | §3.2 pipeline 2 | `push-main.yaml` (affected filter covers it) | `push` | — | Applied via `provision-account.yaml` |
| `${account_id}-customizations-pipeline` (dynamic) | §3.2 dynamic | `_customize-global.yaml` + `_customize-account.yaml` reusables dispatched from `provision-account.yaml` jobs 9-10 and `customize-fleet.yaml` | `workflow_call` | `target_stacks`, `customization_name` | Apply status |

### 11.3 Step Functions

The SFNs are the other half of AFT's pipeline runtime; their GHA replacements are listed here for completeness.

| AFT SFN | `aft-analysis.md` ref | GHA replacement |
|---|---|---|
| `aft-account-provisioning-framework` | §4.4 item 1 | `provision-account.yaml` (12-job DAG §3.2) |
| `aft-account-provisioning-customizations` | §4.4 item 2 | `custom-provisioning-hook.yaml` + optional `components/terraform/custom-hooks/` |
| `aft-invoke-customizations` | §4.4 item 3 | `customize-fleet.yaml` with chunked matrix |
| `aft-feature-options` | §4.4 item 4 | `_feature-options.yaml` (3 gated jobs) |

---

## 12. Out of scope

- Multi-region vended accounts. One `(stack, region)` at a time; multi-region per account = multiple stacks.
- Fleet destroy. `destroy-account.yaml` destroys one at a time by design.
- Rollback. No automatic rollback on apply failure; operator intervention via `import-existing-account.yaml` or stack revert PR.

---

## 13. Reference: files cited

From this repo:
- `docs/architecture/aft-analysis.md` §1-§7
- `docs/architecture/atmos-model.md` §6, §8, §9, §11
- `docs/architecture/mapping.md` §1-§9

From `reference/aft/`:
- `modules/aft-code-repositories/{codepipeline,codebuild}.tf` and `buildspecs/ct-aft-account-{request,provisioning-customizations}.yml`
- `modules/aft-customizations/{codebuild,states/invoke_customizations.asl.json}.tf` and `buildspecs/aft-{global,account}-customizations-terraform.yml`, `buildspecs/aft-create-pipeline.yml`
- `modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json`
- `modules/aft-feature-options/states/aft_features.asl.json`
- `sources/aft-customizations-common/templates/customizations_pipeline/codepipeline.tf`

From `reference/atmos/` (via `atmos-model.md`):
- `reference/atmos/website/docs/cli/commands/describe/describe-affected.mdx`
- `reference/atmos/website/docs/cli/commands/list/list-instances.mdx`
- `reference/atmos/website/docs/cli/commands/terraform/deploy.mdx`
- `reference/atmos/website/docs/ci/ci.mdx`
- `reference/atmos/website/docs/stacks/auth.mdx`
- `reference/atmos/website/docs/stacks/hooks.mdx`
- `reference/atmos/website/docs/integrations/github-actions/affected-stacks.mdx`
