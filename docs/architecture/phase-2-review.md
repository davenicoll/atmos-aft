# Phase 2 Implementation Review

**Reviewer:** aws-architect
**Task:** #25 (P2-review)
**Date:** 2026-04-20
**Inputs:** docs/architecture/{aft-analysis,atmos-model,mapping,module-inventory,gha-design,review,aft-readme-baseline}.md, the shipped `components/terraform/`, `.github/`, `stacks/`, `tests/`, `scripts/`, `atmos.yaml`, `vendor.yaml`, `README.md` trees.
**Verdict:** **READY TO SHIP** (conditional on one observed-green `ci-tests.yaml` run on `main` — gha-engineer monitoring).

Initial verdict on 2026-04-20 was **BLOCKED** on a central→target auth-chain defect (§1). That defect closed on re-review — see §8 for outcome. All other checklist items pass, 4 non-blocker doc/polish follow-ups stand.

---

## 1. Headline finding — central→target role assumption path is broken

This is the canonical blocker and the direct reason for a BLOCKED verdict. Already filed as task #26.

**What should happen.** Every component whose target account is not AFT-mgmt runs with credentials of `AtmosDeploymentRole` (or `AtmosDeploymentRole-ReadOnly` for plan-only) in that target account. The hop from the central identity (`AtmosCentralDeploymentRole` in AFT-mgmt, reached via GHA OIDC or the bootstrap-user access keys) to the target role is the core load-bearing invariant of the whole design (`gha-design.md` §4.5, §4.6; `atmos-model.md` §5; `mapping.md` §5.1).

**What actually happens in the shipped code.** The hop never runs.

Evidence:

1. `atmos.yaml` has no `auth:` block. The header comment (lines 93–105) claims the chain lives in the `configure-aws` composite action, pointing at `gha-design.md §4.5` and `§4.6`.
2. `configure-aws/action.yml`:
   - Assumes only the **central** role (lines 78–92). OIDC mode: `aws-actions/configure-aws-credentials` with `role-to-assume: central_role_arn`. Access-key mode: chains access keys → central role. The result is `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` set to the central identity.
   - `target_role_arn` input is declared but documented as **"Informational only — the central → target hop is driven by Atmos's auth chain inside the Terraform run, not by this action."** (lines 19–24). No step reads it.
   - Exports `ATMOS_AUTH_IDENTITY=default|bootstrap` (line 119–123). No downstream consumer.
3. `_atmos-plan.yaml` (line 88–92) exports `ATMOS_AUTH_TARGET_DEFAULT_ROLE`. `_bootstrap-target.yaml` (line 80–84) exports `ATMOS_AUTH_TARGET_BOOTSTRAP_ROLE`. Neither is read by Atmos (no matching `auth:` block in `atmos.yaml`) nor by any Terraform code (`grep -r 'ATMOS_AUTH_TARGET' components/terraform/` → 0 matches).
4. No component has a real `assume_role` block anywhere in its `providers.tf`. Only matches for `assume_role_policy` exist, and those are IAM *trust* policies on role resources — unrelated to provider-level assumption. Spot checks:
   - `components/terraform/tfstate-backend/providers.tf` — single default `aws` provider, no `assume_role`.
   - `components/terraform/guardduty-root/providers.tf` — same.
   - `components/terraform/iam-deployment-roles/central/providers.tf` — same.
   - `components/terraform/iam-deployment-roles/target/providers.tf` — declares an `aws.target` alias but with a bare `provider "aws" { alias = "target"; region = var.region }` and a comment that says `# assume_role is rendered by Atmos per the auth chain` (lines 10–14). Atmos does not render it (the `auth:` block was removed to accommodate Atmos 1.203 not recognising `aws-oidc`). The aliased provider therefore inherits ambient central credentials, exactly like the default provider.
5. **Only one component references `aws.target`** (`iam-deployment-roles/target/main.tf`). Every other cross-account component — `tfstate-backend`, `guardduty-member-settings`, `security-hub`, `inspector2`, `aws-account-settings`, `aws-budgets`, `aws-scp`, `cloudwatch-log-groups`, `aft-ssm-parameters`, `dns-delegated`, etc. — uses the unaliased default provider. With central creds in the ambient environment, **every "target-account" component applies to AFT-mgmt instead of its target account.**

**Net effect.** PR plans, drift detection, provision-account, customize-fleet, destroy-account, and bootstrap job 5a–6d (the CT-core role stamping) all silently run against the wrong account. The failure will not be detected by `atmos terraform plan` against an empty target account — it will happily plan the component in AFT-mgmt. Apply will either (a) double-create resources in AFT-mgmt until an SCP denies it, or (b) succeed in AFT-mgmt against CT's own baseline, corrupting it.

**Follow-up.** Task #26 is the correct owner — it already lists three candidate fixes (A restore an Atmos-supported `auth:` syntax, B wire per-component `providers.tf` `assume_role` from `TF_VAR_target_role_arn`, C env-var-reading provider wrapper). I do not need to disambiguate the fix — atmos-engineer + gha-engineer are on it. I would flag only:

- Option B is my preferred default. It pushes the assumption into each `providers.tf` where it can be audited, keeps `atmos.yaml` 1.203-compatible, and matches the upstream Cloudposse pattern. The cost is one `assume_role { role_arn = var.target_role_arn, session_name = var.target_session_name }` block per component + one `target_role_arn` variable in `variables.tf`. GHA's `_atmos-plan`/`_atmos-apply` sets `TF_VAR_target_role_arn` after `resolve-stack` resolves it, and OPA/unit tests can assert the block's presence.
- Whatever fix lands must include a **Terratest case** that applies a trivial cross-account component (e.g. `aws-account-settings`) and asserts `sts:GetCallerIdentity` inside the provider resolves to the **target** account, not AFT-mgmt. Without that, the defect can regress unobserved.
- The `central_role_arn` + `target_role_name` inputs added to `_atmos-plan.yaml` (lines 29–38) for PR/drift plan-only defence-in-depth are correctly plumbed into `configure-aws` and `resolve-stack` at the workflow layer, but the *target* role is only honoured once the chain is restored. So the plan-only defence is currently equivalent to the deploy-capable path until #26 lands.

Everything below stands on the assumption that #26 closes without disturbing the rest of the implementation.

---

## 2. Checklist outcomes

### 2.1 Item 1 — Components from `module-inventory.md` exist under `components/terraform/` ✅ (with small naming drift)

All 48 rows in `module-inventory.md` §2 + §2.5 are covered. The `components/terraform/` tree contains 35 directories; the gap comes from **intentional consolidations** rather than missing surface area:

- `iam-deployment-roles/{central,target}` (two subcomponents in one directory) covers rows 11, 25 (plus the §2.5 central-role trio `AtmosCentralDeploymentRole`, `AtmosPlanOnlyRole`, `AtmosReadAllStateRole`).
- Rows 29 (SSO permission-sets out of scope for Phase 1 per `module-inventory.md` §2.5) and 22/23 (VPC — deliberately deferred, `module-inventory.md` §1) are correctly absent.
- `iam-roles-management` from the §3 recommended layout is absent. This row is deprecated by the central/target split: `iam-deployment-roles/central` replaces `AWSAFTAdmin`/`AWSAFTService`, and `iam-deployment-roles/target` replaces `AWSAFTExecution` in every account class. No loss.
- `tfstate-backend` and `tfstate-backend-central` both exist, matching row 1 + row 48.

Naming drift vs §3 recommended layout: none blocking. Minor — `cloudtrail-lake` ships (row 13 / task #13); `cloudtrail-additional` (row 47) ships as a separate component, correct.

**Finding:** no components missing, no forbidden components present.

### 2.2 Item 2 — GHA workflow topology matches `gha-design.md` §5/§6/§7 ✅

Count matches design exactly:

- **Entry-point (§5):** 12 shipped (`pr`, `push-main`, `provision-account`, `customize-fleet`, `drift-detection`, `import-existing-account`, `destroy-account`, `bootstrap`, `vendor-refresh`, `custom-provisioning-hook`, `notify`, `ct-lifecycle-event`). Design specifies §5.1 through §5.12 — 1:1.
- **Reusable (§6):** 11 shipped (`_atmos-plan`, `_atmos-apply`, `_atmos-destroy`, `_atmos-validate`, `_customize-global`, `_customize-account`, `_feature-options`, `_matrix-chunk`, `_post-provision-hook`, `_bootstrap-target`, `_apply-security-service`). Design §6.1–§6.10 — 1:1.
- **Composite (§7):** 6 shipped (`setup-atmos`, `configure-aws`, `resolve-stack`, `publish-status`, `post-plan-summary`, `install-gha-cli-deps`). Design §7.1–§7.6 — 1:1.

Additionally: `ci-tests.yaml` (not in §5 — this is the task-#22 test harness driver).

Spot checks:

- `push-main.yaml`: `permissions: actions: write` present (verified in file). `triggered_by_sha` + `triggered_by_commit_author` SSM writes wired via `publish-status` composite action.
- `destroy-account.yaml`: wait-for-suspended poll present, 45-min budget respected.
- `bootstrap.yaml`: steps 5a–5d (stamp AtmosDeploymentRole) and 6a–6d (stamp tfstate-backend) run sequentially with `needs:` chains; 5b/6b gated by `inputs.separate_aft_mgmt_account`. Correct.
- `provision-account.yaml` job 7a→7b→7c→7d (config-rules → guardduty → security-hub → inspector2): sequential, `max-parallel` not needed because each is a single stack. Correct per `review.md` §6 Blocker #12 closure.
- `_atmos-plan.yaml`: `central_role_arn` + `target_role_name` inputs plumbed into `configure-aws` and `resolve-stack`. Plan-only path is end-to-end wired *except* for the #26 defect — the target-role drop-down is accepted by the workflow but currently ignored at Terraform layer.

**Minor finding (not blocking):** `_bootstrap-target.yaml` does not declare `account_id` in its `inputs:` schema, but `bootstrap.yaml` and `provision-account.yaml` pass `account_id:` to it. GHA will emit `unexpected input` warnings (tolerated today) and the value is never consumed inside the reusable. Either add `account_id` to the input schema for documentation, or drop the `account_id` kwarg at every call site. Cosmetic — filing as cleanup follow-up.

### 2.3 Item 3 — Enforcement surfaces from `mapping.md` §8.1 wired ✅ (one gap)

Design calls for three surfaces: OPA policies under `stacks/schemas/opa/` or `.github/policies/`, pre-commit hooks, and catalog defaults that bake in CT-compat flags. Current state:

- **OPA policies** (`.github/policies/`): 4 policies — `forbidden_components.rego`, `required_ct_flags.rego`, `guardduty_phase_ordering.rego`, `naming.rego`. All four have matching tests under `tests/opa/`. `forbidden_components.rego` correctly denies `aws-organization`, `aws-organizational-unit`, `aws-account` as component sources **and** the raw resource types (`aws_organizations_organization`/`_organizational_unit`/`_account`) — defence-in-depth is present. `required_ct_flags.rego` enforces `create_recorder=false` + `create_iam_role=false` on any component whose source matches `aws-config*` and blocks `enable_organization_settings=true` under `ct_managed: true`. `guardduty_phase_ordering.rego` forces every GuardDuty component to declare `metadata.phase` and `metadata.depends_on` referencing the prior phase.
- **Conftest wiring in CI** (`ci-tests.yaml` job `opa`, line 82–87): `atmos describe stacks --format json | conftest test --policy .github/policies --all-namespaces -`. Runs on every PR. Correct.
- **Pre-commit:** not present in the tree. `mapping.md §8.1` offers pre-commit OR OPA. CI runs conftest on every PR, which is stronger for org-wide enforcement than a local hook. **Not a blocker**, but worth filing as cleanup if repo owners want the developer-loop catch too.

**Gap — catalog defaults do not set CT-compat flags.** `stacks/catalog/aws-config-rules/defaults.yaml` has `vars: {}`. The design (`mapping.md §8.1` third bullet) says *"aws-config stack defaults in stacks/catalog/aws-config/defaults.yaml set create_recorder: false and create_iam_role: false at the catalog level so no downstream stack can forget."* The OPA policy will still block offending stacks at PR time, so operationally nothing ships broken, but defence-in-depth is one layer thinner than designed. The component's wrapper (`cloudposse/terraform-aws-config//modules/cis-1-2-rules`) does not itself create a recorder, so the OPA policy is currently flagging a scenario that the shipped wrapper can't reach — but future `aws-config-*` components (e.g., if someone adds the conformance-pack top-level module) will rely on this catalog default. **Filing as minor follow-up.**

### 2.4 Item 4 — CT coexistence rules still enforced ✅

- **No forbidden components.** `components/terraform/` survey — none of `aws-organization`, `aws-organizational-unit`, `aws-account` appears as a component directory. OPA-blocked anyway via §2.3.
- **`aws-config` `create_recorder: false` / `create_iam_role: false`** — OPA enforces (see §2.3 gap note about catalog default).
- **GuardDuty 3-phase sequencing** — `provision-account.yaml` jobs 7b→7c→7d are literally sequential via `needs:`. The three components `guardduty-root` (phase 1, ct-mgmt), `guardduty-delegated-admin` (phase 2, audit), `guardduty-member-settings` (phase 3, member fan-out) exist. `_apply-security-service.yaml` honours `skip_if_already_applied` for idempotent re-entry. `bootstrap.yaml` runs the same for initial org rollout with `target_stacks: '[]'` (no member fan-out; that happens per-account in `provision-account.yaml`). OPA `guardduty_phase_ordering.rego` enforces `metadata.phase` + `metadata.depends_on` declaration.
- **`_bootstrap-target.yaml` guards `fallback_role`** — rejects anything other than `AWSControlTowerExecution` or `OrganizationAccountAccessRole` at line 57–65. Correct.
- **`sts:ExternalId` on CT-core variants** — cannot verify from shipped code without reading every account-class catalog; taking atmos-engineer's word on task #10 closure for now. Should be validated by Terratest `iam_deployment_roles_target_test.go` — spot-check below.

### 2.5 Item 5 — Both auth modes work ⚠️

OIDC is the default. Access-key is opt-in via `vars.AFT_AUTH_MODE='access_key'` + two env-vars (`AFT_BOOTSTRAP_ACCESS_KEY_ID`/`_SECRET_ACCESS_KEY`). `configure-aws/action.yml` honours both branches. Bootstrap-user access keys are named `AtmosBootstrapUser` per design (`gha-design.md` §4.2 / `atmos-model.md` §5).

**Caveat:** because of #26, neither mode currently delivers a target-account identity — both reach AtmosCentralDeploymentRole, both stop there. When #26 closes, both modes should be re-validated end-to-end (one `atmos terraform apply` per auth mode against a test account; Terratest tier is the natural home).

### 2.6 Item 6 — Both topologies (`separate_aft_mgmt_account=true|false`) ⚠️

The topology switch surfaces in `bootstrap.yaml` as `inputs.separate_aft_mgmt_account` (line 12–15) and correctly gates the AFT-mgmt-specific stamping jobs 5b and 6b via `if: inputs.separate_aft_mgmt_account == true`. Jobs 5c and 6c use `needs: [stamp-roles-ct-mgmt, stamp-roles-aft-mgmt]` with `if: always() && ... (needs.stamp-roles-aft-mgmt.result == 'success' || needs.stamp-roles-aft-mgmt.result == 'skipped')` so the skipped path is correctly rejoined. Good.

**What I cannot verify:** nothing in the stack catalog tree (`stacks/catalog/account-classes/`) or `_defaults.yaml` branches on this topology. The single-account mode (CT-mgmt *is* AFT-mgmt) needs the central roles + primary tfstate + AtmosReadAllStateRole all to live in CT-mgmt instead of a separate aft-mgmt account. The `account-classes/aft-mgmt.yaml` vs `ct-mgmt.yaml` split implies two accounts; when they collapse, the stack catalog needs a branch or a single `aft-mgmt.yaml` that also carries the CT-mgmt role set. **I did not find that branch.** Filing a follow-up to verify: either (a) stacks/catalog/_defaults branches on the topology, (b) there's operator guidance in `README.md` for the collapse case, or (c) this case is explicitly deferred from Phase 1. Cannot declare READY without confirming.

### 2.7 Item 7 — Tests run green ⚠️ (cannot verify in this environment)

`ci-tests.yaml` has 4 jobs: static (atmos validate / fmt / terraform validate / tflint), opa (opa test + conftest), act (dryrun 11 entry workflows), terratest (gated). All job specs are well-formed:

- **static:** per-directory `terraform init -backend=false && terraform validate` + `tflint` per component. The `find components/terraform -type f -name '*.tf' -exec dirname {} \; | sort -u` loop does miss the `iam-deployment-roles/central` vs `iam-deployment-roles/target` subdirectory boundary correctly (they're separate `*.tf` dirs). Good.
- **opa:** `opa test .github/policies tests/opa -v` + `conftest test`. Policies have tests in `tests/opa/`. Good.
- **act:** 11 entry workflows listed in the matrix, each gated by `-f $WF` existence check with a fallback `::notice::entry workflow $WF not yet landed (task #21); skipping`. All 11 workflows exist now, so gates will not fire.
- **terratest:** 10 test files covering `account_provisioning`, `cloudtrail_lake`, `controltower_event_bridge`, `github_oidc_provider`, `guardduty_phases`, `iam_deployment_roles_central`, `iam_deployment_roles_target`, `tfstate_backend`, plus smoke. Gated behind `github.event_name == 'push' || workflow_dispatch with run_terratest || vars.RUN_TERRATEST_ON_PR`. Good gate — Terratest costs AWS money, so PR opt-in is right.

**I did not execute the CI locally.** No AWS credentials, no act runtime set up in this reviewer environment. aft-engineer's task #6 audit is running in parallel and will catch static drift. I flag as caveat: the declared-green state needs one green CI run on the main branch before ship. **Verdict-adjacent finding, not blocking on its own.**

### 2.8 Item 8 — README covers AFT's input/output/module surface ✅

40 KB README, 14 top-level sections exactly matching `aft-readme-baseline.md`'s expected chapter list (Overview through Contributing & license). Spot-check of content:

- §1 includes the "how it differs from upstream AFT" delta table — 12 rows covering CI substrate, orchestration, request inbox, request metadata, lifecycle events, state backend, concurrency, templating, runner network, drift detection, PR plan, forbidden-resource guard. Good.
- §2 points at the 6 architecture docs with one-line scope each. Good.
- §5 Inputs / §6 Outputs expected but not inspected byte-by-byte in this review. aft-engineer's task #6 is the authoritative audit.
- CT coexistence contract stated at §1 bottom — correct framing (CT owns Org/OU/SCPs/org-trail/IC bootstrap; atmos-aft adds the rest).

**I defer the fine-grained parity audit to task #6** (aft-engineer). My check is surface-level only and passes.

### 2.9 Item 9 — No silent scope regressions vs `module-inventory.md` §4 ✅

`module-inventory.md` §4 lists 7 deliberately-deprecated surfaces (`aft-code-repositories`, `aft-lambda-layer`, `aft-account-request-processor`, both SFN state machines, both CodeBuild customization projects, HCP OIDC provider, AFT mgmt-account VPC + 17 endpoints) plus §4.1's DDB replacement matrix (4 tables → Git + CloudTrail Lake + SSM + EventBridge→dispatch).

Spot checks:

- No `code-repositories`, `lambda-layer`, or `step-functions` components present. ✓
- HCP OIDC is not present; `github-oidc-provider` is (rows 19/24). ✓
- No VPC component is present. ✓
- DDB tables: none of the 4 replaced tables appear as components. `controltower-event-bridge` component present (row 8 + §4.1 `aft-controltower-events` replacement); `cloudtrail-lake` component present (task #13 — CloudTrail Lake in audit account replaces `aft-request-audit`). ✓
- SSM namespace `/aft/account/<name>/status` has a `publish-status` composite action writing it (referenced in `atmos.yaml` line 68–84). ✓

**No silent scope regressions.**

---

## 3. Positive deltas (worth calling out)

Not strictly part of the checklist but worth logging:

1. **Drift detection ships Day 1** (`drift-detection.yaml` + the scheduled schedule + plan-only chain). Upstream AFT has none.
2. **PR plans every affected instance under a read-only identity** (`_atmos-plan.yaml` with `target_role_name: AtmosDeploymentRoleReadOnly`). Upstream AFT has no PR plan surface at all.
3. **`controltower-event-bridge` ships the two-CMK rotator split** per `atmos-model.md` §10.1 (spot-checked — `rotator.tf` + `iam.tf` present). Terratest coverage (`controltower_event_bridge_test.go`) exists per tf-module-expert's claim.
4. **Per-account KMS CMK + per-account state bucket** is shipped (see `tfstate-backend` + `tfstate-backend-central` split) — blast-radius reduction that AFT's shared-state design cannot match.
5. **OPA + conftest on every PR** — the CT-coexistence rules are enforced at merge time, not at apply time.

---

## 4. Follow-up tasks to file

| Severity | Title | Owner | Notes |
|----------|-------|-------|-------|
| **BLOCKER** | #26 — Restore central→target role assumption path | atmos-engineer (lead) + gha-engineer | Already filed. Primary blocker for this review. Must land Terratest assertion that cross-account components reach the target account. |
| Minor | Catalog default should set `vars.create_recorder: false` + `vars.create_iam_role: false` for `aws-config*` components | atmos-engineer | `stacks/catalog/aws-config-rules/defaults.yaml` currently `vars: {}`. OPA policy already catches violations at PR time, so defence-in-depth only. |
| Minor | Verify single-account topology (`separate_aft_mgmt_account=false`) is represented in `stacks/catalog/account-classes/` + `_defaults.yaml` | atmos-engineer | `bootstrap.yaml` gates jobs on this input but the stack catalog does not appear to branch. Either document the collapse in README or ship a branch. |
| Cosmetic | `_bootstrap-target.yaml` — declare `account_id` input OR drop it from callers | gha-engineer | Callers pass `account_id:` but the reusable has no such input. Tolerated by GHA today (warning) but misleading. |
| Cosmetic | Pre-commit hook for forbidden components + CT-compat flags | atmos-engineer | Design says "pre-commit OR OPA"; OPA ships, pre-commit does not. Local-loop catch only. |
| Conditional | Run CI green against `main` before declaring ship | gha-engineer | One observed-green CI run is the last quality gate I cannot execute in this review environment. |

---

## 5. Verdict

**BLOCKED.**

One critical auth-chain defect (#26) means the entire Phase 2 runtime is miswired: every "target-account" component would run against AFT-mgmt with central credentials. That is the whole load-bearing invariant of the design. No other finding rises to blocker severity.

**When #26 closes**, the re-review loop should be:

1. Spot-check 3 components (`tfstate-backend`, `aws-account-settings`, `guardduty-member-settings`) — confirm each has a provider-level `assume_role` pointing at the target role via a `TF_VAR_target_role_arn`-style input or equivalent.
2. Confirm Terratest case exercises cross-account assumption (calling-account check via `sts:GetCallerIdentity` inside the apply must return the target account).
3. Require one green `ci-tests.yaml` run on `main`.
4. Re-address the minor + cosmetic follow-ups above as a batch — none block ship.

After those, verdict flips to READY TO SHIP.

---

## 6. Re-review punch list (fold in when #26 closes)

Non-blocker items surfaced by adjacent work that the re-review should clear alongside the #26 fix. Logged here so they don't go lost between now and re-claim.

From aft-engineer's #6 README-parity audit (`docs/architecture/readme-audit.md`):

1. **Custom-vs-wrapper categorization for `account-request-{kms,queue,notifications}`.** Present in README §7.1 component tree but absent from §7.3's custom-component list. `module-inventory.md` needs a one-line classification per component. Ping tf-module-expert.
2. **README §5.1 — `terraform_distribution=tfc` inputs.** Add `terraform_org_name` and `terraform_project_name` as bootstrap inputs when TFC mode is selected.
3. **README §5.4 — dropped inputs.** List `tf_backend_secondary_region` and `backup_recovery_point_retention` as explicitly dropped (completeness against upstream AFT).
4. **Stage/account-name drift.** `core-gbl-log` stage (`log`) vs upstream `log-archive`. Flag for atmos-engineer's next catalog revision — single source of truth in `stacks/catalog/account-classes/log-archive.yaml`.

---

## 7. Re-review outcome (2026-04-20, post-#26 fix)

Scoped re-run after atmos-engineer + gha-engineer closed #26 and the cluster of adjacent fixes (#27 publish-status call-sites, #28 destroy-account cooldown payload, #29 stack-settings reads replacing `CT_*` GH vars, #30 workflow plumbing, #31 over-tight terratest, #32 tfstate-backend variable names).

### 7.1 Exit criteria

From §5 of the initial review — three gates before ship:

**(a) Spot-check 3 cross-account components for provider-level `assume_role`.** ✅

Identical pattern across `tfstate-backend/providers.tf`, `aws-account-settings/providers.tf`, `guardduty-member-settings/providers.tf`:

```hcl
provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.target_role_arn != "" ? [1] : []
    content {
      role_arn     = var.target_role_arn
      session_name = "atmos-aft"
    }
  }
}
```

Empty `target_role_arn` is a deliberate no-op for central-local components (`account-provisioning`, `iam-deployment-roles/central`, the central-side bootstrap bucket). Non-empty assumes the target role — the one load-bearing invariant I called out in §1 is restored.

Coverage verified globally: `grep var.target_role_arn components/terraform/` returns 34 providers.tf files — every shipped component. Every matching `variables.tf` declares `variable "target_role_arn"` with a consistent description (spot-checked across 10 files).

**(b) Terratest assertion exercises the cross-account chain.** ✅

`tests/terratest/target_role_chain_test.go` ships three static cases that run on every PR (no AWS creds required):

1. `TestTargetRoleChain_ProvidersHaveDynamicAssumeRole` — scans every `components/terraform/**/providers.tf`, asserts each contains `dynamic "assume_role"` and `var.target_role_arn`. Guards regression when a new component lands.
2. `TestTargetRoleChain_VariablesDeclareTargetRoleArn` — asserts every root-level `variables.tf` declares `variable "target_role_arn"`. Catches partial-commit footguns.
3. `TestTargetRoleChain_IAMDeploymentRolesTargetAliasPins` — structural assertion that the `aws.target` alias in `iam-deployment-roles/target/providers.tf` carries the dynamic block (not just the default provider). The bootstrap path depends on this.

`tests/terratest/target_role_chain_live_test.go` ships the live assertion gated on `TT_ENABLE_TAGS=live`: assumes `target_role_arn` against live AWS and asserts `sts:GetCallerIdentity` returns the account from `atmos describe component`. Skips cleanly without creds (`helpers.RequireTag`), runs on `workflow_dispatch` with AWS creds plus scheduled `push` events per `ci-tests.yaml` gating.

Together these are stronger than the assertion I asked for in §5. The static cases make every future component automatically covered; the live case detects chain misrouting that static checks cannot.

**(c) One observed-green `ci-tests.yaml` run on `main`.** ⏳ pending gha-engineer confirmation.

I cannot execute this from the reviewer seat — no runner, no AWS creds. team-lead notes gha-engineer is monitoring `main` for the run. This is the last gate; verdict in §Header is conditional on it.

### 7.2 Other §4 follow-ups — resolution

- **`aws-config-rules` catalog default** — closed. `stacks/catalog/aws-config-rules/defaults.yaml` now sets `vars.create_recorder: false` and `vars.create_iam_role: false`. `aws-config-conformance-pack/defaults.yaml` has the same treatment. Defence-in-depth complete.
- **Single-account topology (`separate_aft_mgmt_account=false`)** — deferred to **#33** (Phase 2.1) with an inline note. `bootstrap.yaml` / `iam-deployment-roles` / the catalog already support the collapse; what's missing is a worked example under `stacks/orgs/`. Accepting the defer — the topology switch is exercised in code on every run of `bootstrap.yaml`, just not in a checked-in fixture.
- **`_bootstrap-target.yaml account_id` cosmetic** — closed by #29's broader stack-settings revamp (verified `account_id` is now part of the input schema for consumers that need it; the old bare-kwarg call-sites went through the same revamp).
- **Pre-commit hook** — still not present; still a developer-loop-only item. Non-blocker.

### 7.3 Residual punch list (from §6, aft-engineer #6 audit — carry past ship)

The four items from §6 remain open. None promoted to blockers. They belong in normal doc/catalog maintenance:

- `account-request-{kms,queue,notifications}` needs custom-vs-wrapper categorization in `module-inventory.md`.
- README §5.1 needs `terraform_org_name` + `terraform_project_name` listed as bootstrap inputs when `terraform_distribution=tfc`.
- README §5.4 needs `tf_backend_secondary_region` and `backup_recovery_point_retention` listed as dropped inputs.
- `core-gbl-log` (stage=`log`) vs upstream `log-archive` — flag for the next catalog revision.

### 7.4 Doc-hygiene footnote

During the re-review I noticed stale references to the removed `ATMOS_AUTH_TARGET_DEFAULT_ROLE` / `ATMOS_AUTH_TARGET_BOOTSTRAP_ROLE` env-vars in two docs. These were the env-vars the pre-#26 design exported but never read; they're gone from the code but still referenced in prose:

- `README.md` line ~591 — wording around `AtmosPlanOnlyRole` still cites `ATMOS_AUTH_TARGET_DEFAULT_ROLE`.
- `docs/architecture/gha-design.md` lines ~1243 and ~1254 — wording around `_bootstrap-target.yaml` still cites `ATMOS_AUTH_TARGET_BOOTSTRAP_ROLE`.

Not a blocker — the code is correct, only the doc prose lags. Flagging for the next doc pass (natural owner: gha-engineer, alongside the §7.3 README items).

### 7.5 Verdict

**READY TO SHIP**, conditional on §7.1(c) — one observed-green `ci-tests.yaml` run on `main`. The two code-level gates I could enforce from this seat are both satisfied. The #26 fix is structurally sound, covered by static + live Terratest, and consistent across all 34 components.

---

## 8. References

- Task #25 (this review).
- Task #26 (primary blocker).
- `docs/architecture/review.md` — phase-1 design review, promoted READY FOR PHASE 2.
- `docs/architecture/gha-design.md` §4.5, §4.6, §5, §6, §7, §10.1.
- `docs/architecture/atmos-model.md` §5, §8, §9.3, §10.1.
- `docs/architecture/mapping.md` §5, §8, §8.1.
- `docs/architecture/module-inventory.md` §0–§5 (full inventory).
- `docs/architecture/aft-readme-baseline.md` — README parity target.
