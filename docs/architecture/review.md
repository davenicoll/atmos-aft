# AWS Architect Review: Phase 1 Design

**Reviewer.** aws-architect (teammate)
**Date.** 2026-04-20
**Scope.** `docs/architecture/aft-analysis.md`, `atmos-model.md`, `mapping.md`, `module-inventory.md`, `gha-design.md`.
**Verdict.** **READY FOR PHASE 2** (promoted 2026-04-20). Originally BLOCKED on six design-rework items; all six closed on re-review with verdicts recorded in §6. The design is internally coherent on its core decisions — CT coexistence, IAM chain, Atmos stack shape, GHA topology, configurability, concurrency — and the seams that were blocked are now explicitly documented across `atmos-model.md`, `mapping.md`, `module-inventory.md`, and `gha-design.md`.

Every original blocker has a CLOSED entry in the decisions log (§6) citing the specific documents and sections that close the objection. Non-blockers from §5 may land in phase 2 alongside implementation. The independent-reviewer seat stays open for any design amendments that emerge during implementation.

---

## 1. Review method

I walked the design end-to-end against an AFT capability checklist derived from `reference/aft/main.tf` §1–§7 plus the team-lead ADR on Control Tower coexistence:

- Account-request ingestion and routing (INSERT / MODIFY / REMOVE / existing-CT / shared-account)
- Three-role IAM trust chain and session pinning
- Cross-account state backend topology (S3 + DDB + KMS, primary + secondary region)
- VCS flexibility (6 providers) and TF distribution (oss/tfc/tfe) switches
- Per-account customization pipeline materialisation and fan-out
- Feature-options gating (delete_default_vpcs, enterprise_support, cloudtrail_data_events)
- Concurrency bounds (provisioning, customizations)
- Drift detection, account lifecycle events, notifications
- Import of existing CT-vended accounts
- Every CT-owned resource that an Atmos apply could accidentally touch

I then cross-read the three design documents against each other for internal consistency, not just against AFT.

---

## 2. CT coexistence enforcement — PASS

All three documents honour the hard boundary from the team-lead ADR.

| Rule | Enforcement locus | Status |
|---|---|---|
| Forbidden: `aws-organization`, `aws-organizational-unit`, `aws-account` | `mapping.md` §8, `module-inventory.md` §0.1 table, `gha-design.md` §2.3 policy dir + §5.1 `policy` job + §12.1 row §9.11 | PASS — OPA rule `.github/policies/forbidden-components.rego` runs on every PR. |
| `aws-config` `create_recorder=false`, `create_iam_role=false` | `mapping.md` §8.1, `module-inventory.md` §5.5 | PASS, **with a found gap**: `module-inventory.md` §5.5 correctly documents that the top-level `cloudposse/terraform-aws-config` v1.6.1 module has no `create_recorder` escape hatch — `enabled=false` disables the whole module. Mitigation (use `cis-1-2-rules` / `conformance-pack` submodules, or vanilla) is the right call. No change required. |
| GuardDuty three-phase (delegated-admin → root-delegation → org-settings) | `mapping.md` §8, `module-inventory.md` §2.5 rows 34–36, `gha-design.md` §3.2 job 7 + §12.2 | PASS in principle; phase-ordering verification filed as blocker 6 below. |
| `account-provisioning` = custom component wrapping `aws_servicecatalog_provisioned_product` | `mapping.md` §2.1, `module-inventory.md` row 30, `gha-design.md` §3.2 job 1 | PASS. Service Catalog is the CT vending path; no `aws_organizations_account` anywhere in the design. |
| Additional SCPs only, never CT guardrails | `mapping.md` §8 row "Additional SCPs", `module-inventory.md` row 31 | PASS. |
| Inspector2 safe | `module-inventory.md` §0.3, row 40 | PASS. |

No CT-coexistence regression. Phase 2 can ship these rules with confidence.

---

## 3. Configurability parity with AFT — PASS with one qualified item

AFT's configurable surface and how it maps:

| AFT switch | Replacement | Verdict |
|---|---|---|
| `vcs_provider` (codecommit / github / GHE / bitbucket / gitlab / gl-selfmanaged) | Dropped — GHA replaces it by definition | Acceptable scope cut. Justified in `module-inventory.md` §1 and §4. |
| `terraform_distribution` (oss / tfc / tfe) | Stack-level via `components.terraform.backend_type`; GHA secret `TERRAFORM_CLOUD_TOKEN` (`gha-design.md` §10.1) | PASS. Switchable per stack, no re-bootstrap. |
| Separate aft-mgmt vs single-account topology | `gha-design.md` §3.3 topology switch | PASS. Both work under both auth modes; workflow files are identical. Verified against checklist — one stack-config var `settings.aft_mgmt_account_id` + `ATMOS_CENTRAL_ROLE_ARN` env var. |
| OIDC vs access-key | `gha-design.md` §4.1–§4.3 | PASS. `configure-aws` composite detects mode; both converge on `AtmosCentralDeploymentRole` before any `atmos` call. Access-key path is appropriate for bootstrap and air-gapped test environments. |
| Feature flags (`aft_feature_delete_default_vpcs_enabled`, `aft_feature_enterprise_support`, `aft_feature_cloudtrail_data_events`) | `gha-design.md` §6.6 `_feature-options.yaml` gated on `vars.feature_options.*` | PASS. Per-stack gating preserves the per-account tailoring AFT allows. |
| `concurrent_account_factory_actions` / `maximum_concurrent_customizations` | `gha-design.md` §8.3 `AFT_PROVISION_PARALLELISM` / `AFT_CUSTOMIZE_PARALLELISM` repo vars | PASS with caveat: AFT throttles via FIFO SQS with `maxReceiveCount=1`. Our `ct-provisioning` concurrency group is a single lane, not a configurable N-lane throttle. Blocker 6 calls this out. |
| VPC for AFT management (`aft_enable_vpc`, subnets, endpoints) | Dropped (GHA-hosted runners replace the reason for the VPC) | Acceptable, scope-flagged. Revisit only if self-hosted runners move into AWS. |
| KMS CMK encryption toggles (`cloudwatch_log_group_enable_cmk_encryption`, `sns_topic_enable_cmk_encryption`) | Component-level defaults in catalog | PASS in principle; per-module flag coverage to be verified at implementation. |
| Backup recovery retention on DDB | Tied to outcome of blocker 2 (DDB retention decision) | OPEN until blocker 2 resolves. |

One qualified item: AFT exposes `concurrent_account_factory_actions` as a knob up to the Service Catalog limit; our design is hard-coded to 1. Phase 2 may want a configurable lane count once we confirm with AWS what Service Catalog Account Factory actually serialises (see blocker 6).

---

## 4. Blockers — must resolve before phase 2

These six items require design-level decisions and are filed as follow-up tasks. Each has a forcing function: phase 2 cannot write correct code without the decision.

### Blocker 1: Bootstrap identity into newly vended accounts is undefined

`gha-design.md` §3.2 sequences jobs 3 (`tfstate-backend-target`, in new account) and 4 (`iam-deployment-roles`, creates `AtmosDeploymentRole` in target) *before* `AtmosDeploymentRole` exists. No document states what credentials run those two steps.

In AFT this is handled explicitly: the `create_role` Lambda (`aft-analysis.md` §2 phase D) runs as `AWSAFTExecution` in aft-mgmt, which assumes `AWSControlTowerExecution` in the new account via the providers chain in `reference/aft/providers.tf:1-57`. AFT literally notes this is the only runtime use of `AWSControlTowerExecution`.

Our design implicitly requires the same first-hop into a fresh account, but no component in the inventory, no auth chain in `atmos-model.md` §9, and no reusable workflow in `gha-design.md` §6 names the bootstrap role (`AWSControlTowerExecution` or Service Catalog's default `OrganizationAccountAccessRole`). Without this, phase 2 cannot wire the first apply.

**Fix required.** Name the bootstrap role, document its use in an `Atmos` provider alias (`aws.target_bootstrap`), and add steps to `_atmos-apply.yaml` (or a dedicated `_bootstrap-target.yaml` reusable) that use it exclusively for jobs 3 and 4 of `provision-account.yaml`. After job 4 completes, subsequent jobs revert to the `AtmosDeploymentRole` chain.

Filed as task #7.

### Blocker 2: `mapping.md` and `module-inventory.md` disagree on DDB retention

`mapping.md` §4.1 drops all four AFT DDB tables. Git history + GHA run history is the claimed replacement.

`module-inventory.md` row 4 says **keep** `aft-request`, `aft-request-audit`, and `aft-request-metadata` via `cloudposse/terraform-aws-dynamodb` v0.37.0 "as the source of truth for 'who asked for this account, when, and what happened.'" Row 5 keeps `aft-controltower-events`. Row 15 keeps AWS Backup of those tables.

These are in direct conflict. Phase 2 cannot build "keep and don't keep" the same four tables.

The trade-off is real: GHA run history has a default 90-day retention on public actions and is harder to query than DynamoDB when doing compliance lookups ("who requested account X in Q2 2024"). Git-log only captures *intent*, not execution outcomes. An audit DDB retains both.

**Fix required.** One document decides. Recommendation: keep `aft-request-audit` and `aft-request-metadata` (two tables, not four). Drop `aft-request` (Git is the inbox, stream is unneeded) and `aft-controltower-events` (CloudTrail Lake view in audit account — closes `mapping.md` §9 item 8 simultaneously). Update both documents and `gha-design.md` §9.1 SSM schema table to reference the retained tables as the canonical status source of truth (complements `/aft/account/<n>/status`).

Filed as task #8.

### Blocker 3: State backend topology is ambiguous and cross-account KMS access is undocumented

`mapping.md` §7.1 and `gha-design.md` §3.2 job 3 place a `tfstate-backend` in every vended account. This is a departure from AFT's single-bucket-in-aft-mgmt model where all state keys share one bucket.

Consequences not discussed in any document:

1. **N KMS keys across the fleet.** Each account has its own CMK. `drift-detection.yaml` (§5.5) runs a matrix across every `(component, stack)` instance; each plan call reads state from a different bucket with a different key. The `AtmosCentralDeploymentRole` → `AtmosDeploymentRole` chain gets the right permissions because the target role has AdministratorAccess, but the composite action `post-plan-summary` aggregates plans across accounts — that step runs with central credentials and may touch state from multiple accounts at once.

2. **Initial apply of `tfstate-backend` in each target has a chicken-and-egg.** The component that creates the backend can't use that backend for its own state. AFT side-steps this by applying the central `aft-backend` module with local state, then reusing it. Per-account backend topology either needs a shared bootstrap bucket (per account, with local state first pass) or a central "meta-backend" for bootstrapping all per-account backends. Neither is documented.

3. **AFT's dual-region CMK and cross-region replication** (`aft-analysis.md` §7.1, `tf_backend_secondary_region` variable) is not addressed for the per-account model. `module-inventory.md` §7 item 6 raises this as an open question ("Probably no; simplify to one region unless aws-architect requires DR"). For phase 1 a single-region backend per account is fine. Decision needs to be explicit and written down.

**Fix required.** Pick one of (a) per-account backend with explicit bootstrap procedure and a clear "no DR for phase 1" note, or (b) central backend in aft-mgmt with per-stack keys (matches AFT, preserves AFT's state-lock DDB topology). Whichever path, document the KMS key policy required for `AtmosCentralDeploymentRole` to read state across accounts (for drift, summary aggregation), and document the bootstrap sequence for the backend's own state.

Recommendation: (a) per-account backend. Reasons: matches the "self-contained account" philosophy of the Atmos design; removes the single-bucket-contains-all-state risk; aligns with the existing `iam-deployment-roles` per-account stamping. But the bootstrap + KMS-policy details must be written before phase 2.

Filed as task #9.

### Blocker 4: `AtmosDeploymentRole` placement in CT-mgmt / audit / log-archive is implicit

`gha-design.md` §3.1 names CT-mgmt, AFT-mgmt, audit, log-archive, and "N vended accounts." It says "each hosts `AtmosDeploymentRole`" for vended accounts only.

But the design requires writes into:
- **CT-mgmt**: `aws-scp` attaching policies to OUs; `guardduty/root-delegation` registering delegated admin (`module-inventory.md` row 34); `security-hub` org-admin delegation.
- **Audit**: `guardduty/delegated-admin` org-settings; `security-hub` aggregator; `inspector2` org-settings.
- **Log-archive**: `cloudtrail-additional`, `centralized-logging-bucket` if those stacks exist.

Each of those components needs `AtmosDeploymentRole` (or equivalent) in the respective account. The design doesn't say that explicitly, and doesn't specify whether these roles are stamped by `iam-deployment-roles/target` (which is currently documented as "in every target account" meaning vended only).

**Fix required.** Extend `components/terraform/iam-deployment-roles/target` to be deployable into the four CT-managed accounts (CT-mgmt, AFT-mgmt, audit, log-archive) as part of bootstrap. Add stacks for each under `stacks/orgs/<org>/core/` with `iam-deployment-roles` instance declared. Trust policy in each is identical to the vended-account variant.

Also: the bootstrap workflow (`bootstrap.yaml`, §5.8) currently provisions `AtmosCentralDeploymentRole` in aft-mgmt only. It must also stamp `AtmosDeploymentRole` into CT-mgmt, audit, and log-archive during bootstrap, using the short-lived access-key identity — otherwise the first `provision-account` run cannot write SCPs or configure GuardDuty.

Filed as task #10.

### Blocker 5: `destroy-account.yaml` correctness and `push-main.yaml` permission model

Two smaller-but-real issues in the entry-point workflows:

(a) **`destroy-account.yaml` (§5.7)** returns "succeeded" when Service Catalog accepts the terminate call. CT then asynchronously closes the account over minutes-to-hours. During that window the state says `destroyed` but the account is still active. If the stack file is then re-added (re-use the same email), the next `provision-account` run will race CT's ongoing closure. The design note ("verification that the account is fully closed happens in a follow-up manual step") is not sufficient; operators will forget.

Fix: after the terraform destroy, add a polling job that waits on `aws_organizations_account` status == `SUSPENDED` with a generous timeout (30 min) before writing `status=destroyed` to SSM. Alternatively, accept eventual consistency explicitly and enforce a cooldown before the same stack file can be re-added (via PR check).

(b) **`push-main.yaml` (§5.2) uses `gh workflow run`** to dispatch child workflows. `GITHUB_TOKEN` does **not** grant `actions:write` by default — dispatching another workflow from within a workflow requires either a PAT or an explicit `permissions: actions: write` on the caller. The design doesn't state this. It also changes the audit trail: dispatched runs show the bot as the actor, not the human who merged the PR.

Fix: set `permissions: { contents: read, actions: write }` explicitly in `push-main.yaml`; accept the actor-change and document it; or flip to `workflow_call` with pre-sized concurrency (rejected in §5.2 but with the wrong reason — the stated reason "share one concurrency lease" can be sidestepped with per-call `concurrency:` groups).

Filed as task #11.

### Blocker 6: Three-phase GuardDuty / SecurityHub / Inspector ordering and CT-provisioning concurrency

`gha-design.md` §12.2 already teed this up: "Confirm `settings.depends_on` between three stack instances is actually observed by our workflow DAG". The answer is currently no — `provision-account.yaml` job 7 is documented as "matrix of `_atmos-apply.yaml`" with `max-parallel: 4` (§8.3), which would run all three GuardDuty phases in parallel. Phase 1 needs these serialised.

Separately on §12.2: the `ct-provisioning` global concurrency group is modelled as a single lane. If Service Catalog Account Factory in fact supports concurrent provisioning (CT itself serialises account creation at the Organizations level, but Service Catalog does not necessarily serialise its product-provisioning calls), our single-lane throttle is unnecessarily conservative. AWS docs say the Landing Zone serialises guardrail application but not Service Catalog enqueue. Phase 1 should keep the single-lane default (matches AFT's FIFO SQS `maxReceiveCount=1`) and file the widening as phase 2 tunable.

**Fix required.**
(i) Job 7 of `provision-account.yaml` must be sequential, not matrix-parallel, for the GuardDuty/SecurityHub/Inspector three-phase groups. Either a workflow with explicit `needs:` chain between the three phases, or three separate jobs.
(ii) `ct-provisioning` concurrency stays single-lane for phase 1; add a design note that phase 2 may widen it after empirical testing.

Filed as task #12.

---

## 5. Non-blockers — resolve in phase 2 implementation

These are worth flagging but do not block phase 2 start. They should be addressed in the PRs that introduce the affected components.

1. **`mapping.md` §9 item 8 (CT event history) — close with CloudTrail Lake.** `gha-design.md` §12.2 leaves this open. CloudTrail Lake in the audit account, with an event data store scoped to `AWS Control Tower` source and `Organizations` source, replaces the `aft-controltower-events` DDB table with a queryable, long-retention store. No extra component needed. Decide now so phase 2 adds the data store to the `audit` account's baseline stack.

2. **Service Catalog portfolio access.** The `account-provisioning` component calls `aws_servicecatalog_provisioned_product` against the CT Account Factory portfolio. That portfolio must be shared with whichever account runs the `account-provisioning` component (aft-mgmt in topology A; CT-mgmt in topology B). `module-inventory.md` row 27 does not mention portfolio-share setup. Bootstrap workflow should document this.

3. **`AtmosPlanOnlyRole`** (§4.4) needs `sts:AssumeRole` on `AtmosDeploymentRole-ReadOnly` in every target. That's another per-account role to stamp via `iam-deployment-roles/target`. Add to the component.

4. **AWS Backup.** `module-inventory.md` row 15 keeps AWS Backup only if we keep DDB tables. Once blocker 2 resolves, update row 15 accordingly.

5. **Access-key bootstrap secret rotation (§10.4)** — document that the access-key IAM user (`AtmosBootstrapUser`) is deleted after bootstrap, not just rotated. If retained for repeat bootstraps, the MFA story and audit trail need more detail.

6. **`gha-design.md` §8.3 `max-parallel` values.** Numbers chosen (4, 20) are reasonable but unvalidated. First real provisioning run should empirically confirm, then lock into repo vars.

7. **Drift-detection alerting path.** §5.5 says "GH issue tagged `drift`." Good; also wire to SNS via `notify.yaml` since many ops teams already subscribe to the AFT SNS path.

8. **Bootstrap idempotency.** `bootstrap.yaml` (§5.8) runs once. What happens if it runs twice? Terraform state should make it idempotent, but the documented access-key rotation after bootstrap implies the second run has no credentials. Document "bootstrap is a one-time operation; re-bootstrap requires re-creating `AtmosBootstrapUser`."

---

## 6. Decisions log — re-reviews of blocker fixes

Entries are appended as blocker fixes land. Each records what was re-reviewed, against which original objection, and the verdict.

### 2026-04-20 — Blocker 3 (task #9) CLOSED

Author: tf-module-expert. Files re-read: `atmos-model.md` §8, §9.3, §9.3.1–§9.3.5; `gha-design.md` §5.8, §12.1; `mapping.md` §7.1.

Re-review against the three original objections in §4 Blocker 3:

1. **Cross-account KMS/S3 access for aggregation** — CLOSED. §9.3.2 gives a concrete KMS key policy template with four principals: root, `AtmosDeploymentRole` (local full use), `AtmosCentralDeploymentRole` (cross-account full use for bootstrap writes from aft-mgmt), `AtmosReadAllStateRole` (decrypt-only, gated by `kms:ViaService=s3.<region>.amazonaws.com`). Matching S3 bucket policy grants `AtmosReadAllStateRole` `GetObject`/`ListBucket`/`GetBucketVersioning` only; DenyInsecureTransport is explicit. Permissions boundary on `AtmosReadAllStateRole` denies `s3:Put*`, `s3:Delete*`, `kms:Encrypt*`, `kms:GenerateDataKey*`. `atmos-model.md` §8 redirects cross-stack `!terraform.state`/`!terraform.output` reads from aft-mgmt through this role.

2. **Chicken-and-egg bootstrap** — CLOSED. §9.3.3 encodes a five-step bootstrap order with only step 1 manual (local state) and step 2 a single one-off `terraform init -migrate-state` into the central bootstrap bucket. Steps 3–5 run remote-from-the-start. The central bootstrap bucket in aft-mgmt (`atmos-tfstate-bootstrap-<aft-mgmt-id>-<region>`) holds every account's `tfstate-backend` state plus its own at `bootstrap/self/terraform.tfstate`. Every subsequent workload apply writes directly to the per-account bucket `atmos-tfstate-<account-id>-<region>`. `gha-design.md` §5.8 now mirrors the same ordering.

3. **DR / dual-region** — CLOSED. §9.3.4 makes the Phase 1 position explicit: single-region per account, no cross-region replication, reasoned (durability, conflict-resolution cost, bootstrap blast radius). Optional `secondary_region` variable defined as the escape hatch; §9.3.2 key policy template applies unchanged to a secondary CMK. `mapping.md` §7.1 carries the deferral.

Carry-forward (not a blocker): §9.3.3 step 4 defers the first-touch identity into a new account to task #7 ("task #7 resolves which identity is used for the first touch"). Correct deferral — that is blocker 1's scope. Blocker 3 does not require closing blocker 1 to be closed itself; it only requires that the handoff point is named, which it is.

Minor follow-up worth flagging but not rejecting:

- `tfstate-backend-central` is mentioned in §9.3.3 step 1 as the component applied locally, distinct from the per-account `tfstate-backend` component used everywhere else. `module-inventory.md` will need to add a row for `tfstate-backend-central` when the inventory next updates. File as a housekeeping item in whatever task tracks the inventory refresh; not a design blocker.

Verdict: **Blocker 3 closed.** Phase 2 can build against the §9.3 topology.

### 2026-04-20 — Blocker 5 (task #11) CLOSED

Author: gha-engineer. Files re-read: `gha-design.md` §5.7 (destroy-account.yaml), §5.2 (push-main.yaml), §12.1.

Re-review against the two original objections in §4 Blocker 5:

**(a) `destroy-account.yaml` async correctness — CLOSED.** §5.7 adds an explicit `wait-for-suspended` job (job 8) that polls both ends of the CT async handoff: the Service Catalog record (30 s retry, 10-min cap) and `aws organizations describe-account --account-id … --query 'Account.Status'` expecting `SUSPENDED` (60 s retry, up to 30 min). Total budget 45 min, matching observed CT closure tail. `finalize` (job 9) writes `status=destroyed` only on polling success; on timeout it writes `status=destroy-stuck` and opens a GitHub issue tagged `destroy-stuck`. A scheduled `reconcile-destroyed.yaml` (§5.11.1, Phase 2 follow-on) promotes stuck records once CT catches up. The re-provision race is closed at the PR gate: §5.7 adds a 7-day cooldown in `pr.yaml`'s policy job that rejects re-adding a stack whose email is in `status=closing` or `destroyed_at` within 7 days, with a `cooldown-override` label as the AtmosAdmin escape hatch. The "operator will forget" concern from my original write-up is structurally addressed.

**(b) `push-main.yaml` permission model — CLOSED.** §5.2 now states the permissions block explicitly: `{ contents: read, id-token: write, actions: write }`, with a clear sentence explaining that `GITHUB_TOKEN`'s default `contents: read` does not carry `actions: write` and the REST `workflows/.../dispatches` call requires it. Actor-change is documented: dispatched runs show `github-actions[bot]` but the merging human is recovered via `github.event.head_commit.author` in the `push-main` logs and persisted into SSM by `publish-status` as `triggered_by_sha` + `triggered_by_commit_author`. My original review's complaint about audit-trail loss is resolved by the SSM write, not by swapping to a PAT. The PAT path is offered as an override (`secrets.WORKFLOW_DISPATCH_PAT`) for orgs whose compliance demands the human actor on dispatched runs, with the trade-off (rotation toil) surfaced. The earlier `workflow_dispatch` vs `workflow_call` choice is also revisited with the correct rationale (run-lifetime decoupling, not concurrency sharing).

Verdict: **Blocker 5 closed.** Both halves of the fix are concrete and exercise the right mechanisms. No follow-up needed from a review perspective; the `reconcile-destroyed.yaml` scheduled workflow is a Phase 2 implementation task for gha-engineer to track.

### 2026-04-20 — Blocker 6 (task #12) CLOSED

Author: gha-engineer. Files re-read: `gha-design.md` §3.2 (provision-account DAG), §5.8 (bootstrap.yaml), §6.10 (new `_apply-security-service.yaml`), §8.3 (matrix parallelism), §12.1.

Re-review against the original §4 Blocker 6 objections:

**(i) Sequential three-phase enforcement — CLOSED.** The new `_apply-security-service.yaml` (§6.10) makes the phase chain a structural invariant, not a scheduling convention: `phase-1-delegate` → `propagate` (30 s sleep + IAM probe against `list-organization-admin-accounts`, 15 s retry, 5-min cap) → `phase-2-org-config` → `phase-3-member-settings`. The three stages are connected by hard `needs:` edges with no cross-phase matrix; only phase-3 fans out, and only after phases 1+2 have converged. The `propagate` step is the piece my original review didn't specify but clearly needed — AWS `*-organization-admin-account` APIs have observable propagation latency and the probe closes that window before phase 2 fires.

At the workflow-fan-out layer, `provision-account.yaml` job 7 is split into `7a config-rules` → `7b guardduty` → `7c security-hub` → `7d inspector2` with `needs:` between services, not a cross-service matrix. §8.3 row for job 7 pins `max-parallel: 1` with the note "correctness invariant, not performance knob" and no repo-var override. Rationale for cross-service serialisation (shared delegated-admin account, `aws_*_organization_admin_account` IAM interleave observed in AFT integration testing) is written into §8.3.

First-run bootstrap: §5.8 step 5 calls `_apply-security-service.yaml` once per service with empty `target_stacks` and `skip_if_already_applied=false`, sequential across services. Preconditions are explicit (CT audit account must be ACTIVE) and fail-fast via `describe-account`.

Steady-state per-account vends use `skip_if_already_applied=true`, probing for `aws_<service>_organization_admin_account` presence and short-circuiting to phase 3 only. This preserves the "phases 1+2 must have run" invariant while avoiding wasteful org-level re-applies on every vend — a detail I hadn't thought through in the original review, but it's the right call.

**(ii) `ct-provisioning` concurrency single-lane — CONFIRMED.** No change to the global single-lane default, which matches my original recommendation to leave it as-is for Phase 1 and file widening as a Phase 2 empirical tuning task. No regression.

Minor cross-doc note: §5.7 destroy-account job 3 explicitly states phase-3 member settings are torn down per-account but phases 1 and 2 are **never** torn down by account destroy — they are fleet-wide and owned by `customize-fleet.yaml`. That's the right guardrail; noting it so it surfaces if anyone later proposes bundling phase-1/2 teardown into destroy.

Verdict: **Blocker 6 closed.** The `_apply-security-service.yaml` abstraction is a cleaner solution than my original "either separate workflows per phase with `needs:` or per-service job ordering" dichotomy — it's one reusable that encodes both shapes behind `skip_if_already_applied`. Phase 2 can build against §6.10 directly.

### 2026-04-20 — Follow-up questions from gha-engineer on blockers 5 & 6

1. **Is 45-min total budget for `wait-for-suspended` sufficient?** Keep 45. AFT's own runbooks and public AWS CT write-ups cluster typical closure at 15–30 min with a long tail to ~40. Extending to 60–90 does not reduce the stuck-rate meaningfully; it just occupies a runner longer on a failing case. The real long-tail mitigation is `reconcile-destroyed.yaml` (scheduled Phase 2 reconciler) — that, not the inline poll, is the correct place to absorb operational outliers.

2. **`list-organization-admin-accounts` false-positive propagation?** Rare but possible. The API returns the principal once AWS's Organizations-side registry has accepted the registration, which is *typically* complete before the cross-account service-linked role in the audit account is fully usable for org-wide config. If phase 2's first apply hits `BadRequestException`, the AWS Terraform provider's built-in retry will cover transient cases, and phase 2 is idempotent on re-run. Accept the 30 s default for Phase 1; if operations sees repeated phase-2 retries in dashboards, bump `propagation_wait_seconds` to 60–90 as an empirical tuning — no design change needed.

3. **Sequential bootstrap services — parallelise?** Keep sequential. The same cross-service contention that motivates `provision-account.yaml` job 7 serialisation (shared delegated-admin account, `aws_*_organization_admin_account` IAM interleave) applies during bootstrap too; parallelising the three service stamps into the same audit account at first-run is exactly the race we banned for steady-state. The 9–15 min added is bounded, one-time per org, and executes during a human-approved maintenance window. Widening belongs on the same "future phase may widen after empirical validation" line §8.3 already carries — not now.

### 2026-04-20 — Blocker 1 (task #7) CLOSED

Author: atmos-engineer. Files re-read: `mapping.md` §5.4; `gha-design.md` §3.2 identity-per-job table, §4.5, §4.6, §5.3 handoff paragraph, §5.8, §6.9.

Re-review against the original §4 Blocker 1 objection — "no component in the inventory, no auth chain in `atmos-model.md` §9, and no reusable workflow in `gha-design.md` §6 names the bootstrap role":

**Problem split (A vs B) — CLOSED.** `mapping.md` §5.4 separates the two genuinely distinct bootstrap moments: (A) one-time central-role + OIDC provider stamping in aft-mgmt via `bootstrap.yaml`, and (B) per-new-account target-role stamping in jobs 3–4 of `provision-account.yaml`. Conflating them, which the original design did, was the root cause of the gap.

**Chain named — CLOSED.** `gha-design.md` §4.5 writes the chain explicitly: `OIDC → AtmosCentralDeploymentRole → AWSControlTowerExecution` for CT-vended accounts, with `OrganizationAccountAccessRole` as the fallback for CT-managed core accounts. The central role's attached policy includes `sts:AssumeRole` on all three target arms (`AtmosDeploymentRole`, `AWSControlTowerExecution`, `OrganizationAccountAccessRole`). Mirrors AFT's `AWSAFTAdmin → AWSAFTExecution/AWSControlTowerExecution` fan-out exactly.

**Atmos `auth:` alias — CLOSED.** `atmos.yaml` now declares a `target-bootstrap` provider alias and a `bootstrap` identity. The two components that need the elevated chain (`tfstate-backend`, `iam-deployment-roles/target`) pin `bootstrap` as the default identity in their stack-catalog defaults, so Atmos resolves to `AWSControlTowerExecution` automatically for those two components and `AtmosDeploymentRole` for everything else. No per-call override at the workflow layer; the handoff from job 4 → job 5 is a natural consequence of stack-catalog resolution, not an explicit switch step. This is the piece I didn't sketch in the original review — it's cleaner.

**Reusable workflow — CLOSED.** `gha-design.md` §6.9 defines `_bootstrap-target.yaml`, functionally identical to `_atmos-apply.yaml` but sets `ATMOS_AUTH_IDENTITY=bootstrap`. Callers are confined to `provision-account.yaml` jobs 3 + 4 and `bootstrap.yaml` stamping into the four CT-managed core accounts. The env var is set in one file; a grep for `_bootstrap-target.yaml` enumerates every elevated-chain call site. That is the enforcement surface I wanted.

**Dependency on blocker 4 (#10):** explicit — §4.5 names task #10 for the CT-managed-account placement rules, which is correct scope.

Verdict: **Blocker 1 closed.** The solution is tighter than my original "name the bootstrap role, add steps to `_atmos-apply.yaml` or a dedicated `_bootstrap-target.yaml`" — it picks the latter *and* pushes identity selection down into stack-catalog pinning so workflows don't carry the branching logic.

### 2026-04-20 — Blocker 2 (task #8) CLOSED

Author: atmos-engineer. Files re-read: `module-inventory.md` §2 rows 4/5/15, §3 component layout, §4.1 replacement matrix, §7 question 7, §8 change log; `mapping.md` §4.1.

Re-review against the original §4 Blocker 2 objection — two documents in direct contradiction on whether to keep DDB tables:

**Contradiction resolved — CLOSED.** `module-inventory.md` rows 4, 5, and 15 all now read "Dropped." `mapping.md` §4.1 and `module-inventory.md` §4.1 agree: all four DDB tables gone. The AWS Backup component that existed only to back up those tables is also dropped. `account-request-ledger/` and `aft-backup/` removed from §3 component layout. Change log entry is explicit.

**Replacement matrix — CLOSED.** §4.1's four-row matrix does the work my original review asked for:
- `aft-request` → Git (stack YAML *is* the request; `atmos describe affected` on merge resolves it).
- `aft-request-audit` → CloudTrail Lake event data store in audit + `git log` on the repo (7-year default retention; git is permanent). This also closes `mapping.md` §9 item 8 (CT event history) — the two compliance-audit stores collapse to one.
- `aft-request-metadata` → `atmos describe stacks` for declared state + `/aft/account/<n>/status` SSM for runtime state. Notably, SSM writes happen *inside* the target account rather than from mgmt — each account owns its own status row, which is a cleaner trust model than AFT's central DDB.
- `aft-controltower-events` → EventBridge rule on CT default bus → API destination + connection (GitHub App/PAT in Secrets Manager) → `repository_dispatch`. No Lambda in the path; the `controltower-event-bridge` component is the one new module required.

Implementation notes flag three real details: SSM cross-account read policy, EventBridge→dispatch auth surface, and GHA run-log 90-day retention with an archive-to-S3 escape hatch.

**Two carry-forward questions:**

- *Q7 — CloudTrail Lake: CT-provided or new `cloudtrail-lake` component?* My read: CT **does not** provision CloudTrail Lake. CT sets up a classic CloudTrail organisation trail and a Config aggregator; Lake is a separate service with a separate event data store. A `cloudtrail-lake` component in the audit stack is needed. Recommended shape: one event data store, `TerminationProtectionEnabled=true`, retention 7y (AWS default, billable per GB-month), advanced-event-selector scoped to `AWS::CloudTrail::Event` with `eventSource IN (controltower.amazonaws.com, organizations.amazonaws.com, servicecatalog.amazonaws.com, sts.amazonaws.com)` so the table covers the AFT-request audit path and the CT lifecycle path in one store. Upgrade to 10y retention is a per-installation policy knob — default 7y. File as a Phase 2 component task.

- *Q8 — EventBridge → GHA dispatch auth (GitHub App vs PAT)?* gha-engineer's call per team-lead's routing. My preference for the record: **GitHub App installation token**, not PAT. A PAT ties the mgmt-account's EventBridge path to a single human's credential with rotation toil and leave-of-absence risk; a GitHub App is an org-level identity with scoped `contents:read, actions:write` and token lifetime managed by GitHub. The App approach also keeps audit clean: dispatched runs show the App name, not "dn@..." If gha-engineer picks PAT for Phase 1 expediency, accept it with a note that the App is the Phase 2 target.

Verdict: **Blocker 2 closed.** The design is now internally consistent, the replacement matrix is concrete per-surface, and the SSM ownership pattern is a minor but real improvement over AFT's centralised DDB model.

### 2026-04-20 — Blocker 3 tie-in in `module-inventory.md` §2.6 ACCEPTED

Author: tf-module-expert. Files re-read: `module-inventory.md` §2 row 1 + row 48, §2.6.1–§2.6.5, §8 change log.

Context: I had flagged in the blocker-3 closure above that `tfstate-backend-central` was mentioned in `atmos-model.md` §9.3.3 but missing from `module-inventory.md`. This tie-in closes that carry-forward and adds operational depth.

- Row 48 (`tfstate-backend-central`) added; same v1.9.0 backing module as row 1, separate component because its shape is aft-mgmt-only and its bucket/key-prefix/alias inputs differ. Exactly the disambiguation I wanted.
- §2.6.2 confirms v1.9.0 supports the shape: `create_kms_key=true` default, `use_lockfile` available from v1.8.0+, `dynamodb_enabled=false`. No version bump needed.
- §2.6.3 surfaces the one non-native piece: cross-account `AtmosReadAllStateRole` grant. Path chosen is correct — `source_policy_documents` for S3 (keeps the extra statement co-located with the bucket the module generates) and a sibling `aws_kms_key_policy` resource re-applying the full §9.3.2 template for KMS. Important that both ship inside `components/terraform/tfstate-backend/main.tf` rather than as stack-YAML overrides; that's exactly where they belong.
- §2.6.4 clarifies the one-time `migrate-state` is aft-mgmt's own `tfstate-backend` state only. Every other account's bootstrap state stays in the central bucket permanently. That's a cleaner mental model than "eventually migrate everything" — the bootstrap state is small, read-rarely, and moving it buys nothing.
- §2.6.5 per-account CMK at $1/month × 200 accounts × 1 region = $200/month; acceptable for the blast-radius gain.

No conflicts with atmos-model.md §9.3 or gha-design.md §5.8. Tie-in accepted; blocker 3 remains closed with the module-inventory coverage now complete.

### 2026-04-20 — Follow-up questions from gha-engineer on CT-lifecycle dispatch auth

Four questions on the `gha-design.md` §5.12 / §10.1 dispatch-auth design (Mode A GitHub App, Mode B PAT fallback, bespoke rotator Lambda):

1. **Rotator cadence — 45 min on a 1h token.** Tighten to **30 min**. 45 min gives 15 min margin, which is thin against Lambda cold-start plus network blips plus GitHub API transient failures. GitHub App installation tokens are cheap to mint (one `POST /app/installations/:id/access_tokens` call, no quota pressure). A 30-min cadence means one missed rotator execution still leaves 30 min of cushion before events start 401'ing. The marginal cost is trivial (a few hundred additional Lambda invocations per month); the margin gained is not.

2. **Retry buffer — 24h enough for a weekend outage?** No. Worst case (rotator fails Friday evening, nobody paged until Monday morning) exceeds 24h. The API destination's built-in 24h retry is a short-term cushion, not a weekend cushion. Recommend: attach an **SQS DLQ** to the API destination target, with a CloudWatch alarm on DLQ depth (`> 0` for 5 min → SNS). SQS buys up to 14 days of retention out of the box and replay is a single `aws sqs receive-message` loop when the rotator is restored. Don't use S3 archive for this — replay from S3 requires custom tooling and duplicate-suppression; SQS is the right primitive.

3. **Secrets Manager built-in rotation framework vs bespoke Lambda.** Keep **bespoke**. SMR's four-step `RotateSecret` protocol (`createSecret` → `setSecret` → `testSecret` → `finishSecret`) is designed for DB credentials with atomic swap semantics; our case is "mint a short-lived token from a long-lived PEM," which is fundamentally simpler. The alerting benefit SMR gives is reproducible with two CloudWatch metric alarms on a bespoke Lambda (error-count > 0, plus a downstream `GetSecretValue` age alarm via a custom metric). Over-engineering the framework match is more cost than value here.

4. **GitHub App `Actions: write` blast radius.** That is the minimum permission for `POST /repos/:o/:r/dispatches` — fine-grained permissions do not go per-endpoint. Effective blast radius: anyone with the App installation token can trigger any workflow in the one installed repo. Mitigations already planned (one-repo install, Secrets Manager IAM boundary on who reads the token) are sufficient. Residual concern: a compromise of the rotator Lambda's role would let an attacker refresh the token and dispatch arbitrary workflows. Mitigation: restrict the rotator Lambda's IAM to `secretsmanager:PutSecretValue` on only the target secret ARN and `kms:Encrypt/Decrypt` on only the secret's KMS key — no wildcards. Document the App scope and the Lambda's IAM boundary in the Phase 2 runbook.

Recorded in the decisions log. gha-engineer can proceed with the modifications inline; no separate re-review needed unless the SQS DLQ addition uncovers a larger redesign.

### 2026-04-20 — gha-engineer dispatch-auth acknowledgment CLOSED

gha-engineer confirmed all three recommendations recorded and added a post-launch empirical-tuning note to §6.10 citing the `list-organization-admin-accounts` false-positive window and the `propagation_wait_seconds=60–90` escape hatch. No design changes. Bootstrap sequential-across-services and the 45-min destroy budget stay as-shipped. Loop closed.

### 2026-04-20 — EventBridge → `repository_dispatch` auth amend (§5.12 / §10.1 / §10.4) CLOSED

gha-engineer's amend matches the Q8 answer above: Mode A GitHub App (installation tokens rotated by a bespoke rotator Lambda) as default, Mode B fine-grained PAT as fallback, selected by `controltower-event-bridge` component's `vars.github_auth_mode`. Dedupe via concurrency keyed on `client_payload.event_id` for EventBridge at-least-once delivery. Matches the pattern exactly — no further review needed.

Carry-forward into the amend (from my four-question response above): tighten rotator cadence to 30 min, add SQS DLQ on the API destination target with CloudWatch alarm on depth, keep bespoke rotator over Secrets Manager's `RotateSecret` framework, restrict rotator Lambda IAM to scoped `secretsmanager:PutSecretValue` + `kms:Encrypt/Decrypt` on only the target secret/key ARNs. gha-engineer to reflect in §5.12/§10.1/§10.4 inline; no separate re-review.

### 2026-04-20 — Blocker 4 (task #10) CLOSED — `AtmosDeploymentRole` placement in CT-core accounts

Author: atmos-engineer. Files re-read: `gha-design.md` §3.1, §4.6.1, §4.6.2, §5.8 (steps 5–8); `mapping.md` §8 "Deployment roles" row; `module-inventory.md` row 25 + §8 change log.

Re-review against the original §4 Blocker 4 objection — "§3.1 says CT-mgmt, AFT-mgmt, audit, log-archive, and N vended accounts host `AtmosDeploymentRole` for vended accounts only. But aws-scp / GuardDuty / SecurityHub / CloudTrail etc. need it in the CT-core accounts too, and the design doesn't say that explicitly":

**All five classes named explicitly — CLOSED.** `gha-design.md` §3.1 now lists each class with the concrete component instances that require `AtmosDeploymentRole` there: CT-mgmt gets it for `aws-scp`, `guardduty/root`, `security-hub/org-admin-delegation`, `inspector2/delegated-admin`, `identity-center-permission-sets`, and the `controltower-event-bridge` rule; audit gets it for `guardduty/delegated-admin`, `security-hub/aggregator`, `inspector2/org-settings`, `cloudtrail-lake`; log-archive gets it for `cloudtrail-additional` and `centralized-logging-bucket`; AFT-mgmt gets it for the central-plane components or is covered by CT-mgmt's instance when `separate_aft_mgmt_account=false`; vended gets it for everything in provision-account.yaml jobs 5–12. The pattern matches `module-inventory.md §2.5` component placements row-by-row.

**Trust policy template — CLOSED with one noted guardrail.** §4.6.2 gives the canonical trust policy: principal = `AtmosCentralDeploymentRole` ARN, `sts:ExternalId` condition on the four CT-core variants (extra guardrail because those accounts existed before Atmos), `aws:userid` match on `atmos-*` session names to enforce that assumption paths always use the `configure-aws` composite's canonical session-name format. The ExternalId variant is the piece I didn't specifically call for but is the right call: the CT-core accounts have a different blast-radius profile (they hold Organization-level state), and a static per-org UUID via the `ATMOS_EXTERNAL_ID` GHA var costs nothing to enforce and blocks a misconfigured central-role assume from an adjacent org/repo.

**Bootstrap stamping path — CLOSED.** §4.6.2's diagram makes the chain explicit for the CT-core placements: GHA → `AtmosCentralDeploymentRole` → `OrganizationAccountAccessRole` (pre-existing in all four core accounts since Organizations creation) → terraform apply stamps `AtmosDeploymentRole`. Preferring `OrganizationAccountAccessRole` over `AWSControlTowerExecution` is correct — the former exists in CT-mgmt (where `AWSControlTowerExecution` does not), so one fallback value covers all four CT-core placements uniformly. The `_bootstrap-target.yaml` `fallback_role` input (§6.9) takes `OrganizationAccountAccessRole` for CT-core and `AWSControlTowerExecution` for vended, defaulting to the vended case.

**Bootstrap workflow — CLOSED.** §5.8 step 5 adds four sequential `_bootstrap-target.yaml` calls (5a CT-mgmt, 5b AFT-mgmt with `separate_aft_mgmt_account=true` skip, 5c audit, 5d log-archive), each stamping `iam-deployment-roles/target`. Step 6 mirrors the pattern for `tfstate-backend` per-core-account. The sequential ordering rationale is written into §5.8: `AtmosCentralDeploymentRole`'s cross-account `sts:AssumeRole` policy was just created in step 3, so transient IAM propagation is the likely failure mode and serial runs give per-account failure attribution. Step 7 (fleet-security phase 1+2 init) now correctly notes that from this point on, applies use the default identity — `AtmosDeploymentRole` now exists in CT-mgmt and audit. The `separate_aft_mgmt_account=false` case is handled cleanly: 5b and 6b skip, the CT-mgmt instance serves both workloads. Preconditions (CT audit + log-archive active) fail-fast via `describe-account` before step 7 runs.

**Cross-doc consistency — CLOSED.** `mapping.md §8` "Deployment roles" row names all five classes, the two fallback values, and cross-refs `gha-design.md §4.6.1`. `module-inventory.md` row 25 (`iam-roles-target-account`) is expanded to cover all five classes with stamping workflow and fallback role per class; §3 directory comment matches; change log entry is explicit.

**Policy attached — `AdministratorAccess` in all five classes.** §4.6.2 is explicit: the boundary lives at `AtmosCentralDeploymentRole`'s `sts:AssumeRole` resource list (already pinned to `*:role/AtmosDeploymentRole`, `*:role/AWSControlTowerExecution`, `*:role/OrganizationAccountAccessRole` in §4.5) plus SCPs, not at the per-component role level. Per-component least-privilege is explicitly deferred and tracked in §12.3. This matches the AFT precedent (`AWSAFTExecution` is effectively admin) and is the correct Phase 1 posture — splitting the target-role into per-component least-privilege roles adds significant complexity without a clear first-user win.

Minor observation (not a rejection): the §4.6.2 table says `AtmosDeploymentRole-ReadOnly` is stamped by "the same `iam-deployment-roles/target` component, extra role resource." That is a clean place to co-locate the two roles; §4.4 already introduced the read-only role so the stamping pattern was implicit. Making it explicit closes a small gap I hadn't flagged.

Verdict: **Blocker 4 closed.** The design now names every role placement, the trust policy with its ExternalId guardrail, the stamping workflow, the fallback identity, and the component placement per class. Phase 2 can build against §3.1 + §4.6 + §5.8 steps 5–7 without another round of disambiguation.

### 2026-04-20 — All six blockers closed. Verdict promoted to READY FOR PHASE 2.

With Blocker 4 (#10) closed above, all six design-rework items from the original §4 are resolved:
- #7 Bootstrap identity — CLOSED
- #8 DDB retention — CLOSED
- #9 State/KMS topology — CLOSED (plus module-inventory §2.6 tie-in)
- #10 CT-core role placement — CLOSED
- #11 destroy async + push-main permissions — CLOSED
- #12 GuardDuty 3-phase sequencing — CLOSED

All three carry-forwards from the original review (§9 items, CloudTrail Lake scope, EventBridge→dispatch auth) are resolved in the decisions log. The design documents now present a single coherent story across `atmos-model.md`, `mapping.md`, `module-inventory.md`, and `gha-design.md`, with no cross-document contradictions and no unresolved seams at bootstrap edges.

Phase 2 implementation may begin. Independent-reviewer seat remains open for any further design amendments that emerge during implementation; standard PR review will cover the component and workflow code itself.

---

## 7. Silent capability losses — accepted

Each scope cut in `module-inventory.md` §4 has a justification; I agree with all seven:

| Cut | Why it's fine |
|---|---|
| CodeBuild / CodePipeline | GHA replaces by definition. |
| AFT Lambdas + layer | No runtime Lambdas once orchestration moves to GHA. |
| AFT SQS + processor | GHA workflow dispatch is the equivalent. |
| AFT VPC + 17 endpoints | Only existed to give in-account CodeBuild a private path. Gone with CodeBuild. |
| HCP Terraform OIDC provider | Replaced by GitHub OIDC provider (`module-inventory.md` row 24); `terraform_distribution` flag still works for state storage. |
| Per-account CodePipeline | Replaced by matrix dispatch. |
| `AWSAFTService` role | Used only for Service Catalog portfolio share; CT already has that covered. Acceptable, verify via blocker 4 that no component needs a distinct service identity. |

The four items where AFT behaviour legitimately disappears without replacement are called out explicitly in `mapping.md` §10 "Net new risks" and each has a mitigation.

---

## 8. Positive deltas over AFT

Worth naming, because they aren't accidents:

1. **Drift detection built-in** (`gha-design.md` §5.5). AFT has none.
2. **Plan-before-apply on every PR** (`gha-design.md` §5.1). AFT's CodePipeline has no PR step; plans run only after merge.
3. **Read-only IAM identity for PR runs** (§4.4, `AtmosPlanOnlyRole`). AFT has a single privileged role per stage.
4. **Forbidden-components OPA policy** (§2.3, §5.1 policy job). AFT has no equivalent runtime guard against `aws-organization`-style resources.
5. **`use_lockfile: true` S3-native state locking** (`mapping.md` §7.1, `module-inventory.md` §7 question 4). Drops the DDB lock table AFT always ran.

These justify the migration effort on their own merits, independent of the CodeBuild/CodePipeline replacement.

---

## 9. Verdict

**BLOCKED** on six items (tasks #7–#12 filed). The design is internally coherent on its core decisions — CT coexistence, IAM chain, Atmos stack shape, GHA topology, configurability, concurrency. The blockers are all at the *seams* between the three design documents or at bootstrap edges that were deferred.

Once the six blockers land as doc updates (not code), the design is **READY FOR PHASE 2**. My rough estimate: a focused half-day of design work closes all six; the rest of phase 2 is implementation against a clean spec.

---

## 10. Reference: files cited

From this repo:
- `docs/architecture/aft-analysis.md` — all seven sections used as the AFT baseline.
- `docs/architecture/atmos-model.md` — §6, §8, §9, §11, §12.
- `docs/architecture/mapping.md` — §1, §2, §4, §7, §8, §9, §10.
- `docs/architecture/module-inventory.md` — §0, §1, §2, §2.5, §3, §4, §5.5, §7.
- `docs/architecture/gha-design.md` — §2, §3, §4, §5, §6, §8, §9, §10, §11, §12.

From `reference/aft/`:
- `main.tf`, `providers.tf`, `locals.tf`.
- `modules/aft-iam-roles/iam.tf` and submodule trust policies.
- `modules/aft-backend/main.tf`.
- `modules/aft-account-provisioning-framework/states/aft_account_provisioning_framework.asl.json`.
- `src/aft_lambda/aft_account_request_framework/aft_invoke_aft_account_provisioning_framework.py`.
