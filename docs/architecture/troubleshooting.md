# Troubleshooting atmos-aft

This guide catalogues the failure modes operators encounter when running atmos-aft, the signals that identify each one, and the remediation that usually works. It is organised by the layer at which the failure surfaces: Control Tower, IAM/auth, Service Catalog account provisioning, GitHub Actions orchestration, Terraform/Atmos execution, state and locking, and customization workflows. For each entry we note *how you know* (the log line, CloudTrail event, or workflow error you will actually see) and *what to do* (ordered remediation, least-destructive first).

If your failure is not listed here, capture the GitHub Actions run URL, the Atmos component and stack, the affected account ID, and the CloudTrail event ID, then open an incident ticket against this repo before attempting recovery.

---

## 1. Control Tower preconditions

atmos-aft does **not** manage Control Tower itself. A misconfigured or mid-upgrade landing zone will surface as opaque failures in provisioning and baselining. Diagnose CT first.

### 1.1 Landing zone not deployed or not current

**Signal.** `provision-account` workflow fails at the Service Catalog step with `ResourceNotFoundException` on product `AWS Control Tower Account Factory` or `ProvisioningArtifactNotFoundException`. In the CT console, the landing zone shows status `Not Deployed`, `Failed`, or `Update Available`.

**Cause.** Control Tower must be deployed and current in the management account before atmos-aft can provision accounts. When CT has an update pending, the Account Factory product version referenced by the provisioning call may no longer exist.

**Fix.**
1. In the CT console, update or deploy the landing zone to the current version.
2. Re-run `provision-account` for the pending request.
3. If the Account Factory product ID has changed, verify the atmos-aft management-account component reads the product ID dynamically (data source), not a pinned value.

### 1.2 OU not registered with Control Tower

**Signal.** Provisioning fails with `ManagedOrganizationalUnit <name> is not registered with Control Tower`. CT console shows the OU exists in Organizations but is not under CT management.

**Fix.** In the CT console, register the OU. Wait for the `Registered` status before retrying the provision workflow. Do not create OUs outside CT - OUs are CT-owned under the coexistence contract.

### 1.3 CT drift or in-progress lifecycle event

**Signal.** `CreateManagedAccount` / `UpdateManagedAccount` events are not arriving on the `aft-events-from-ct-management` EventBridge bus (in atmos-aft, the equivalent signalling path). CT shows `Lifecycle in progress` or individual accounts show `Enrolled (drifted)`.

**Fix.** Wait for CT to finish its lifecycle operation - concurrent account creates will fail against an in-flight CT operation. For drifted accounts, trigger a CT repair from the console; do not attempt to re-baseline from atmos-aft until drift clears.

### 1.4 Guardrails blocking baseline execution

**Signal.** Baseline workflow fails with `AccessDenied` on an API call that the `AWSControlTowerExecution` → `AtmosDeploymentRole` chain should permit. CloudTrail shows `errorCode: AccessDenied` with `errorMessage` referencing an SCP.

**Cause.** A CT-managed preventative guardrail (SCP) is blocking the baseline action, or a custom SCP attached to the OU conflicts with the baseline scope.

**Fix.** Identify the SCP from the CloudTrail event (`additionalEventData.policiesEvaluated`). If it is a CT-managed mandatory guardrail, the baseline component must not attempt that action - remove the offending resource from the baseline. If it is a custom SCP, decide whether to scope the baseline differently or to amend the SCP; do **not** detach a CT-managed mandatory guardrail.

---

## 2. IAM, OIDC, and role-chaining failures

atmos-aft replaces AFT's long-lived `AWSAFTAdmin` hub role with short-lived OIDC sessions from GitHub Actions. Most auth failures fall into three buckets: OIDC trust misconfigured, role-chain assumption denied, or session tags/externalId mismatch.

### 2.1 `Not authorized to perform sts:AssumeRoleWithWebIdentity`

**Signal.** GitHub Actions job fails at the `aws-actions/configure-aws-credentials` step with `Not authorized to perform sts:AssumeRoleWithWebIdentity`.

**Diagnostics.**
1. Confirm the OIDC provider exists in the target account: `aws iam list-open-id-connect-providers` - URL must be `https://token.actions.githubusercontent.com`, thumbprint current.
2. Inspect the target role's trust policy: the `StringEquals`/`StringLike` conditions on `token.actions.githubusercontent.com:sub` and `:aud` must match the current workflow.
3. Check that the workflow file requests the correct permissions:
   ```yaml
   permissions:
     id-token: write
     contents: read
   ```
   Missing `id-token: write` is the single most common cause.

**Fix.** If the OIDC provider is missing, bootstrap the management account identity setup first. If the trust policy `sub` claim is too narrow, broaden it to the expected `repo:<org>/<repo>:ref:refs/heads/<branch>` or `repo:<org>/<repo>:environment:<env>` pattern. Never open the trust to `*`.

### 2.2 `AtmosCentralDeploymentRole` assumes, but chained role assumption fails

**Signal.** Step 1 of the chain succeeds (OIDC → `AtmosCentralDeploymentRole` in management account). Step 2 (management → member `AtmosDeploymentRole`) fails with `AccessDenied`.

**Diagnostics.**
1. In the target member account, read `AtmosDeploymentRole` trust policy. The `Principal` must be the management-account `AtmosCentralDeploymentRole` ARN (or the management account root if you trust the whole account).
2. If the trust policy uses a session-name condition (equivalent to AFT's pinned `AWSAFT-Session`), confirm the Atmos hook is setting the session name it expects.
3. If `sts:ExternalId` is required, confirm the caller supplies it - matrix jobs and workflow_call invocations both need to propagate it.

**Fix.** Correct the trust policy or the caller's session-name / ExternalId. Audit `CloudTrail` in the member account for `AssumeRole` events with `errorCode: AccessDenied` to see the exact condition that failed.

### 2.3 Role assumption succeeds but Terraform calls get `AccessDenied`

**Signal.** AssumeRole succeeds; subsequent `terraform plan`/`apply` fails on a specific API with `AccessDenied`. CloudTrail shows the call was made as `AtmosDeploymentRole` but the permission is missing.

**Cause.** Either the role's attached policy is too tight, or an SCP at the OU level blocks the action, or the resource has a resource-policy denying the principal.

**Fix.** Read the CloudTrail event's `additionalEventData`: if `policiesEvaluated` includes an SCP denial, escalate to the OU owner. If it is a role-policy gap, expand `AtmosDeploymentRole`'s policy document in the management-account component and re-deploy. For resource-policy denials (S3 bucket policies, KMS key policies), update the resource policy - do not grant `AtmosDeploymentRole` cross-account admin as a workaround.

### 2.4 IAM propagation delay after bootstrap

**Signal.** Immediately after bootstrapping a new account or creating a new role, the first workflow run fails with `AccessDenied`, but the identical run succeeds on retry 30–60 seconds later.

**Cause.** IAM is eventually consistent. Newly created roles, policies, and trust relationships take up to 60 seconds to propagate globally.

**Fix.** Do not chase this in code. Workflows should include a bounded retry at the `configure-aws-credentials` step (retry on `AccessDenied`, max 3 attempts, 20s backoff). Do **not** add `sleep` steps - retry semantics are the correct fix. If retries exhaust, the problem is not propagation; return to §2.1–§2.3.

### 2.5 Plan-only vs apply role confusion

**Signal.** PR preview plan succeeds; merge-to-main apply fails with `AccessDenied` on a write action. Or: plan output shows resources the apply role cannot create.

**Cause.** `AtmosPlanOnlyRole` (read-only) was granted to the apply path, or `AtmosDeploymentRole` (write) has been scoped down below what the component needs.

**Fix.** Verify the GitHub environment protection rules map PR workflows → `AtmosPlanOnlyRole` and `main` branch workflows → `AtmosDeploymentRole`. Read the workflow file's `role-to-assume` input per job.

---

## 3. Service Catalog account provisioning

Account creation goes through Control Tower's Service Catalog product, same as upstream AFT. Failures here are usually Service Catalog's eventual consistency, CT concurrency limits, or request-record mismatches.

### 3.1 Duplicate account request - email or name collision

**Signal.** `provision-account` workflow fails with `ProvisionedProductName already exists` or Service Catalog reports `DuplicateResourceException` on the email address.

**Cause.** The account email is the primary key throughout AFT's model - atmos-aft inherits this invariant. A previous failed provision left a `ProvisionedProduct` record, or the account already exists in Organizations.

**Fix.**
1. Check Organizations: `aws organizations list-accounts --query "Accounts[?Email=='<email>']"`. If the account exists, it must be imported, not re-provisioned.
2. Check Service Catalog: `aws servicecatalog search-provisioned-products --filters SearchQuery="<email>"`. If a terminated/failed `ProvisionedProduct` exists, terminate it cleanly via Service Catalog before retrying.
3. Never bypass the email PK - pick a new email rather than force-delete records.

### 3.2 Control Tower concurrency limit hit

**Signal.** Multiple concurrent `provision-account` jobs fail with `ConcurrentModificationException` or the CT console shows several accounts stuck in `Provisioning` with only one making progress.

**Cause.** Control Tower serialises account lifecycle operations - only one CreateManagedAccount or UpdateManagedAccount may be in flight at a time per landing zone.

**Fix.** Do **not** run `provision-account` as a broad matrix. Use a single-concurrency GitHub Actions concurrency group:
```yaml
concurrency:
  group: ct-provision
  cancel-in-progress: false
```
If multiple provisions queued outside this guard, cancel all but one, wait for the active one to complete, then release the rest sequentially.

### 3.3 Provisioning succeeded but downstream routing did not fire

**Signal.** Account appears in Organizations under the target OU and CT console shows `Enrolled`, but no baseline ran. In upstream AFT this would be "DDB stream did not fire the routing Lambda". In atmos-aft, the analogue is "the CT event did not trigger the baseline workflow".

**Diagnostics.**
1. CloudTrail in the management account: search for `CreateManagedAccount` success events. Confirm the event hit the atmos-aft event bridge/trigger path.
2. GitHub Actions: inspect `repository_dispatch` / `workflow_dispatch` history for the baseline workflow. The triggering event should have been emitted by the CT bridge Lambda (or equivalent).
3. Confirm the account request record in the request store (DynamoDB table in the management account, equivalent of AFT's `aft-request`) was written and matches the account email.

**Fix.** If the routing dispatch did not fire, run `baseline-account` manually against the new account. File the missed-dispatch incident - routing gaps must not be accepted silently.

### 3.4 `UpdateManagedAccount` path used when CT has no update pending

**Signal.** Baseline run triggered by an `UpdateManagedAccount` event fails because the account was not actually updated (CT reported `AWS_CONTROL_TOWER_ACCOUNT_UPDATE_FAILED` or no update was pending).

**Cause.** atmos-aft (like AFT) uses both create and update events to drive re-baseline. If CT emits `UpdateManagedAccount` for drift repair but the repair itself failed, the downstream baseline will try to run against an account in an unknown state.

**Fix.** Repair CT drift first (§1.3). Only then re-run the baseline.

### 3.5 Request stuck in the request queue

**Signal.** The account request record exists in DynamoDB with `request_status = PENDING` (or equivalent) and never transitions. No CloudTrail provision event is emitted.

**Cause.** The request dispatcher (FIFO queue consumer, equivalent of AFT's `aft-account-request-processor`) is not draining.

**Diagnostics.** Check the SQS FIFO queue (if used) for message count and DLQ. Check the dispatcher Lambda or workflow for recent invocations. Check for a schema mismatch in the request record - the dispatcher will drop malformed records.

**Fix.** Repair the dispatcher. Records in the DLQ must be inspected and either re-queued (if transient) or discarded with an explicit ticket (if malformed).

---

## 4. GitHub Actions orchestration

### 4.1 Matrix exceeds the 256-job ceiling

**Signal.** `describe affected --format matrix` produces a matrix with > 256 entries; the workflow fails to start with `The matrix "include" array must not exceed 256 elements`.

**Cause.** Organisation-wide change (provider version bump, global component change) expanded the affected set beyond the single-workflow limit.

**Fix.** Fall through to the distributed-map path (S3 iterator, equivalent of AFT's `aft-invoke-customizations` SFN distributed map). The entry-point workflow must detect matrix overflow and dispatch a chunked workflow that reads account shards from S3. Never truncate the matrix silently.

### 4.2 `workflow_call` permission propagation failure

**Signal.** A reusable workflow invoked via `workflow_call` fails at OIDC time with `id-token` permission denied, even though the caller set `id-token: write`.

**Cause.** `workflow_call` requires the callee to also declare `permissions:` explicitly. The callee does not inherit the caller's permissions - it inherits the intersection of caller permissions and its own declaration.

**Fix.** Add `permissions: id-token: write, contents: read` to the reusable workflow's top-level block.

### 4.3 Environment approval gate stuck

**Signal.** Workflow run shows `Waiting` against an environment; required reviewers never receive a notification.

**Cause.** Environment protection rules reference a reviewer team that has been renamed, deleted, or removed from the repo's access list.

**Fix.** Repository settings → Environments → select env → verify reviewers. Approvers must have at least Write on the repo.

### 4.4 OIDC session duration too short for long applies

**Signal.** Long-running `terraform apply` (large account baseline) fails midway with `ExpiredToken`.

**Cause.** Default OIDC session is one hour. Large applies (Config recorders, many CloudTrail trails, full SecurityHub enablement) can exceed that.

**Fix.** Set `role-duration-seconds` on `aws-actions/configure-aws-credentials` up to the role's `MaxSessionDuration` (set the role's max to 4h where needed; never exceed 12h). Do **not** refresh credentials mid-apply - Terraform cannot pick up a new session cleanly.

### 4.5 `repository_dispatch` event never received

**Signal.** Upstream caller posts a `repository_dispatch` and expects a workflow to run; no run appears in the Actions tab.

**Diagnostics.**
1. The dispatching token must have `repo` scope (or `actions: write` on a fine-grained token).
2. The target workflow must have `on: repository_dispatch: types: [<type>]` listing the exact type string.
3. The target workflow must exist on the **default branch** - `repository_dispatch` always runs the default branch copy.

**Fix.** Correct the branch/type/token. Do not debug with `workflow_dispatch` as a substitute - the routing contract depends on `repository_dispatch`.

---

## 5. Terraform and Atmos execution

### 5.1 `atmos describe affected` returns empty when you expect changes

**Signal.** PR changes a component but `describe affected --format matrix` returns `[]`. CI skips the apply.

**Cause.** Atmos compares against the merge-base; if the PR branch is behind `main` in a way that hides the change, or if the component change is in a file not tracked as a component source (e.g., a helper script outside the component dir), affected-detection will miss it.

**Fix.**
1. Rebase onto `main` and re-run.
2. Verify the change is under a path Atmos considers a component source. Helper scripts called from a component should live inside the component dir.
3. As a last resort, force a full-fleet run via the `workflow_dispatch` scheduled-drift workflow - but capture the miss as a detection bug and fix affected-detection.

### 5.2 `atmos validate stacks` fails on a stack you did not touch

**Signal.** Validation fails on an unrelated stack after merging a catalog change.

**Cause.** Catalog imports are transitive. A change to a shared catalog file propagates to every stack that imports it.

**Fix.** Read the validation error. The fix is almost always in the catalog file, not the stack - revert or correct the catalog change. Atmos's import graph makes this a feature: a broken catalog fails every importer loudly rather than silently.

### 5.3 Forbidden component attempted

**Signal.** Plan shows creation of `aws-organization`, `aws-organizational-unit`, or `aws-account`. OPA policy in CI blocks the plan.

**Cause.** Someone attempted to manage CT-owned resources from atmos-aft. These are forbidden under the coexistence contract.

**Fix.** Remove the component from the stack. Organizations, OUs, and account creation are CT-owned - they must never appear in an atmos-aft plan. Do not disable the OPA check.

### 5.4 Config/GuardDuty/Inspector conflict with CT-managed resource

**Signal.** Baseline plan shows a destroy+recreate of a Config recorder, GuardDuty detector, or Inspector enablement. Apply fails with `already exists` or `cannot delete CT-managed resource`.

**Cause.** CT already manages a Config recorder, GuardDuty delegated admin, or Inspector per its guardrails. Our baseline must use the CT-compat flags (adopt-existing rather than create).

**Fix.** Set the CT-compat flag on the component (e.g., `ct_managed_config_recorder = true`). The component must data-source the existing recorder instead of creating a new one. See the CT coexistence memory entry for the full flag matrix.

### 5.5 Distributed map S3 iterator not finding shards

**Signal.** Large-fleet workflow dispatches but individual shard jobs fail with `NoSuchKey` on the S3 iterator bucket.

**Cause.** The shard-publish step (writes account chunks to S3) ran in a different account/region than the shard-consume jobs expect, or the iterator bucket has a lifecycle rule expiring objects before consumers read them.

**Fix.** Pin the iterator bucket to the management account's home region. Disable lifecycle expiration on the iterator prefix, or set it to ≥ 7 days (longer than any reasonable fleet apply window).

---

## 6. State, backends, and locking

### 6.1 `Error acquiring the state lock`

**Signal.** `terraform plan`/`apply` fails with `Error acquiring the state lock`. DynamoDB-based locking is the upstream AFT path; atmos-aft uses S3-native locking (`use_lockfile = true`).

**Diagnostics.**
1. Check the S3 backend bucket for a `<key>.tflock` object. Inspect its metadata - it records the runner that holds it.
2. Check the Actions run corresponding to that runner. If it is still running, wait.
3. If the run has terminated (failed, cancelled) and the lock persists, it is orphaned.

**Fix.** For an orphaned lock: delete the `.tflock` object in S3 after verifying the runner is not active. Do **not** `-lock=false` - that bypass will corrupt state under concurrent writes. If this happens frequently, the workflow is not cleaning up on cancellation; add a `post-run` step that releases the lock.

### 6.2 State backend access denied from plan role

**Signal.** Plan job fails with `AccessDenied` on `GetObject` of the state backend bucket. Apply role succeeds against the same bucket.

**Cause.** `AtmosPlanOnlyRole` is missing `s3:GetObject` / `kms:Decrypt` on the per-account state backend, or the `AtmosReadAllStateRole` used for cross-account plan previews does not trust the plan role.

**Fix.** Audit the plan role's policy: it needs read + decrypt on every per-account state bucket/CMK it plans against. Apply roles have write; plan roles have read. Do not consolidate the roles.

### 6.3 Per-account CMK rotation breaks old state access

**Signal.** After CMK rotation, `terraform plan` against an account fails with `KMSInvalidStateException` or decryption errors.

**Cause.** State files encrypted with an old CMK version cannot be decrypted if the old version is pending deletion or disabled.

**Fix.** CMKs managed by atmos-aft must have automatic annual rotation (not manual), and old key versions must remain enabled. If a CMK was manually rotated and an old version was disabled, re-enable it. Never delete a CMK version that has encrypted state files.

### 6.4 Backend config drift (Jinja template vs. rendered state)

**Signal.** `terraform init` against an imported account reports the backend has changed; state migration prompt appears or `Backend initialization required` blocks the run.

**Cause.** In upstream AFT, `backend.jinja` is rendered per account. In atmos-aft, backend config is derived from stack metadata. A mismatch between the previously rendered backend (from AFT) and the new Atmos-derived backend surfaces as drift.

**Fix.** Part of the migration contract (see `migration-from-aft.md` §4). For a fresh import, ensure the Atmos backend block matches the actual S3 key the state currently lives at. If the backend truly must change, `terraform init -migrate-state` once, under a controlled lock, then commit the new backend config.

---

## 7. Customization workflows

### 7.1 Global customization fails on one account but succeeds on others

**Signal.** `customize-global` matrix run shows 1 of N jobs failing; the failure is account-specific.

**Cause.** Usually: an account-local resource conflicts with the global intent (e.g., a manually created S3 bucket with the same name as the global template creates), or per-account IAM is drifted.

**Fix.** Inspect the failing plan. If it is a naming collision, rename the account-local resource. If it is drift, re-run the account's baseline before re-running the customization.

### 7.2 Per-account customization runs the wrong module version

**Signal.** Customization applies an older or newer version of a module than expected.

**Cause.** `vendor.yaml` pin in the customizations repo does not match the deployed state, or `atmos vendor pull` has not been run on the runner.

**Fix.** Pin module versions explicitly in `vendor.yaml` using immutable refs (commit SHA or semver tag, never `main`). Run `atmos vendor pull` at the start of every customization job. CI should fail if `git status` shows uncommitted vendor changes after pull.

### 7.3 Provisioning SFN → GHA rewrite: step ordering broken

**Signal.** During migration, a customer's previously-working AFT account-provisioning state machine does not behave the same when ported to GitHub Actions - downstream steps run before upstream ones complete.

**Cause.** SFN's `Next`/`Choice` semantics are explicit; GHA `needs:` is likewise explicit but matrix fan-out without a synchronising `needs` can parallelise steps that used to be serial.

**Fix.** Read the original SFN. Any `Sequential` block or explicit `Next` chain must become `needs:` dependencies in GHA. Do not use `if:` conditionals as a substitute for ordering.

### 7.4 Customization hit the CT-managed resource boundary

**Signal.** Customization tries to modify a CloudTrail trail, Config recorder, or other CT-managed resource and fails with `cannot modify CT-owned resource`.

**Cause.** Customer ported a customization that was already broken in AFT - or worked in AFT only because AFT ran with a role that had broader privileges than our least-privilege `AtmosDeploymentRole`.

**Fix.** Remove the customization. CT-owned resources are off-limits to customizations regardless of role privilege. If the customer needs to extend CT behaviour (e.g., forward CloudTrail logs elsewhere), do it through a separate trail, not by modifying the CT trail.

---

## 8. Observability and audit

### 8.1 CloudTrail search for a specific assume-role chain

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRole \
  --start-time <iso8601> \
  --max-results 50 \
  --query 'Events[?contains(CloudTrailEvent, `AtmosDeploymentRole`)]'
```

Run this in the **member account** to see which caller assumed the role, with what session name, and whether any conditions were evaluated. For cross-account chains, run it in each hop account.

### 8.2 Correlating a GitHub Actions run to CloudTrail events

The OIDC token's `aud`, `sub`, and `jti` claims are passed into the `AssumeRoleWithWebIdentity` call and appear in CloudTrail under `requestParameters.providerIdentifier` / `additionalEventData`. Use the workflow run ID (from the GHA URL) to grep CloudTrail. Every chained AssumeRole inherits the session name; set the session name to the run ID to make correlation trivial.

### 8.3 Missing run logs

**Signal.** A workflow run terminated hours ago; logs are truncated or missing for one job.

**Cause.** GitHub retains logs for 90 days by default and truncates per-step logs above 4 MB. Verbose Terraform output can blow past that.

**Fix.** For long applies, enable `TF_LOG=INFO` only on failure (via a follow-up re-run), not as the default. Capture plan/apply outputs as workflow artifacts at the end of each job (`actions/upload-artifact`) so they survive beyond log retention.

---

## 9. Escalation and recovery playbooks

### 9.1 Account stuck in a half-provisioned state

If an account appears in Organizations but is not enrolled in CT, or is enrolled but never received a baseline, do not attempt to "fix" it with manual IAM or resources. Order of operations:

1. Confirm CT state (console + `aws controltower get-landing-zone`).
2. If CT shows drift, repair from CT console.
3. If CT shows healthy but the request record is missing, write the request record manually and re-run routing.
4. If CT shows healthy and the request record is correct, manually trigger `baseline-account`.
5. Only after 1–4 fail should the account be terminated via Service Catalog and re-provisioned.

### 9.2 Losing credentials mid-flight

If `AtmosCentralDeploymentRole` or `AtmosDeploymentRole` is deleted or has its trust policy corrupted while runs are in flight, all in-flight runs will fail on their next AWS call. Do not attempt to "recover" a run - let it fail cleanly, fix the trust policy, and re-run.

### 9.3 Full-fleet drift after an upstream module change

A provider or module change that affects every account will produce a large `describe affected` matrix (potentially the distributed-map path, §4.1, §5.5). Before dispatching:

1. Pilot the change on a small OU (`sandbox`, or a dedicated `canary` OU) using a scoped Atmos workflow.
2. Review plans for unexpected destroys.
3. Stage the rollout by OU tier (sandbox → non-prod → prod), not all at once.
4. Keep a rollback plan: the previous module version must be re-pinnable in `vendor.yaml`.

### 9.4 When to open an incident vs. retry

- **Retry**: IAM propagation (§2.4), transient AWS API throttling, orphaned state lock under 5 minutes old.
- **Incident**: anything in §1 (CT preconditions), §3.3 (missed routing dispatch), §5.3 (forbidden component reached plan), §6.3 (CMK rotation breakage), §7.4 (customization touched CT resource), or any repeated failure of the same kind within 24 hours.

Incident tickets should capture: affected account IDs, workflow run URL, first failing CloudTrail event ID, the Atmos component + stack, and the last known-good run for the same path.

---

## Appendix A - Diagnostic command reference

```bash
# List all accounts in Organizations with OU path
aws organizations list-accounts-for-parent --parent-id <ou-id>

# Fetch a specific ProvisionedProduct record
aws servicecatalog describe-provisioned-product --id <pp-id>

# List OIDC providers
aws iam list-open-id-connect-providers

# Inspect a trust policy
aws iam get-role --role-name AtmosDeploymentRole \
  --query 'Role.AssumeRolePolicyDocument'

# Show current S3 backend lock object
aws s3api list-objects-v2 --bucket <state-bucket> \
  --prefix <account-id>/ --query "Contents[?contains(Key, '.tflock')]"

# Atmos: re-derive affected set for the current PR
atmos describe affected --format matrix \
  --base-ref origin/main --head-ref HEAD

# Atmos: validate all stacks (should always pass on main)
atmos validate stacks
```

## Appendix B - Common error-to-section index

| Error text (substring) | See section |
| --- | --- |
| `ResourceNotFoundException` on Account Factory product | §1.1 |
| `ManagedOrganizationalUnit ... not registered` | §1.2 |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | §2.1 |
| `AccessDenied` after AssumeRole succeeded | §2.3 |
| Intermittent `AccessDenied` immediately after IAM change | §2.4 |
| `ProvisionedProductName already exists` | §3.1 |
| `ConcurrentModificationException` on CT provision | §3.2 |
| Account provisioned but no baseline ran | §3.3 |
| GHA matrix > 256 jobs | §4.1 |
| `id-token` permission denied in callee workflow | §4.2 |
| `ExpiredToken` mid-apply | §4.4 |
| `describe affected` empty when change expected | §5.1 |
| Plan creates `aws-organization` / `aws-organizational-unit` | §5.3 |
| Config/GuardDuty/Inspector destroy-recreate in plan | §5.4 |
| `Error acquiring the state lock` | §6.1 |
| `KMSInvalidStateException` on state read | §6.3 |
| `Backend initialization required` after import | §6.4 |
| Customization hit CT-owned resource | §7.4 |
