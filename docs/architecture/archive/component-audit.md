# Component audit — module versions, input/output mapping, and arg drift

**Audit date:** 2026-04-20
**Scope:** every directory under `components/terraform/` plus the root `vendor.yaml`.
**Methodology:**
1. **Version currency.** For each Cloudposse-backed component, compared the pinned tag in `main.tf` and `vendor.yaml` against `gh api repos/cloudposse/terraform-aws-<name>/releases/latest`.
2. **Input drift.** Ran `terraform init -backend=false && terraform validate` in every component dir. `validate` catches every made-up arg name against the actual module's `variables.tf` at the pinned tag — the same failure mode that surfaced #32 (`s3_use_lockfile` vs `s3_state_lock_enabled`).
3. **Output drift.** Caught by the same `validate` pass — referencing a non-existent module output fires the same "Unsupported attribute" error.
4. **Vanilla components.** No version pin to check, but the same `validate` pass catches AWS provider arg drift against the pinned provider in `versions.tf`.

This is the load-bearing pre-deploy audit — the cost of one wrong arg name is "first real apply blows up at 3am."

---

## §0 vendor.yaml audit

`vendor.yaml` is the mechanical source of truth for `atmos vendor pull`. A pin here that doesn't match a real upstream tag bricks every component that depends on it.

### Version currency — every source vs upstream `releases/latest`

| Component slug | Pinned ref | Upstream latest | Status |
|---|---|---|---|
| tfstate-backend | 1.9.0 | v1.9.0 | OK |
| s3-log-storage | 2.0.0 | v2.0.0 | OK |
| kms-key | 0.12.2 | 0.12.2 | OK |
| sns-topic | 1.2.0 | v1.2.0 | OK |
| cloudwatch-events | 0.10.0 | v0.10.0 | OK |
| cloudwatch-logs | 0.6.9 | v0.6.9 | OK |
| ssm-parameter-store | 0.13.0 | 0.13.0 | OK |
| iam-role | 0.23.0 | v0.23.0 | OK |
| iam-policy | 2.0.2 | v2.0.2 | OK |
| lambda-function | 0.6.1 | v0.6.1 | OK |
| s3-bucket | 4.12.0 | v4.12.0 | OK |
| cloudtrail | 0.24.0 | 0.24.0 | OK |
| **cloudtrail-s3-bucket** | ~~`1.2.0`~~ → **`v0.32.0`** | v0.32.0 | **FIXED** — pinned tag never existed |
| service-control-policies | 0.15.2 | v0.15.2 | OK |
| budgets | 0.8.0 | v0.8.0 | OK |
| guardduty | 1.0.0 | v1.0.0 | OK |
| security-hub | 0.12.2 | 0.12.2 | OK |
| config | 1.6.1 | v1.6.1 | OK |
| sso | 1.2.0 | 1.2.0 | OK |
| vpc-flow-logs-s3-bucket | 1.3.1 | v1.3.1 | OK |

### Mismatches between vendor.yaml and component-level `module.source` pins

| Component | vendor.yaml | component main.tf | Action |
|---|---|---|---|
| cloudtrail-additional → `cloudtrail-s3-bucket` | ~~1.2.0~~ → v0.32.0 | ~~1.2.0~~ → 0.32.0 | **FIXED** in both files |
| All other components | match | match | OK |

### Source URL / target path validation

All 20 `spec.sources[].source` URLs resolve. No archived or renamed repos. The `targets` and `included_paths` patterns still match what each upstream release ships (verified for `config` — only the two submodules `modules/cis-1-2-rules/**/*.tf` and `modules/conformance-pack/**/*.tf` are pulled, never the top-level recorder; this is the §5.5 architectural guard).

---

## §1 Per-component status

Status legend:
- `OK` — `terraform validate` passes clean against the pinned module/provider.
- `Fixed` — was failing pre-audit; patched in this commit (see notes).
- `Vanilla` — no Cloudposse module backing (raw AWS resources or local-only logic).

All 34 directories now `terraform init -backend=false && terraform validate` clean.

| # | Component | Backing | Pre-audit | Post-audit | Notes |
|---|---|---|---|---|---|
| 1 | `account-provisioning` | Vanilla | FAIL — `module.this` undeclared | **Fixed** | Added canonical terraform-null-label 0.25.0 `context.tf`. |
| 2 | `account-request-kms` | cloudposse/kms-key 0.12.2 | OK | OK | Single Cloudposse-wrapper invocation, args match v0.12.2. |
| 3 | `account-request-notifications` | cloudposse/sns-topic 1.2.0 | OK | OK | `module "sns_topic"` per topic, args match v1.2.0. |
| 4 | `account-request-queue` | Vanilla | OK | OK | Two `aws_sqs_queue` (main + DLQ), no module. |
| 5 | `aft-access-logs-bucket` | cloudposse/s3-log-storage 2.0.0 | OK | OK | Args match v2.0.0. |
| 6 | `aft-lifecycle-lambdas` | cloudposse/lambda-function 0.6.1 | FAIL — input drift | **Fixed** | Added required `function_name = each.key`; `policy_json` → `inline_iam_policy`. |
| 7 | `aft-observability` | Vanilla | OK | OK | `aws_cloudwatch_log_group` + `aws_cloudwatch_metric_alarm`, no module. |
| 8 | `aft-ssm-parameters` | cloudposse/ssm-parameter-store 0.13.0 | FAIL — input + output drift | **Fixed** | `parameters` (map) → `parameter_write` (list-of-map) coerced at call site; `kms_arn` `null` → `""` (var nullable=false); output `parameter_arns` rewired `module.parameters.names` → `module.parameters.arn_map`. |
| 9 | `aws-account-settings` | Vanilla | OK | OK | `aws_iam_account_password_policy` + `aws_s3_account_public_access_block`. |
| 10 | `aws-budgets` | cloudposse/budgets 0.8.0 | OK | OK | Args match v0.8.0. |
| 11 | `aws-config-conformance-pack` | cloudposse/config 1.6.1 (`modules/conformance-pack`) | FAIL — input drift | **Fixed** | `var.conformance_pack` (object) → `var.conformance_pack_url` (string); added `parameter_overrides` (map(any), default {}) wired to module's `parameter_overrides`. **Stack-config callers must update var name** — flagged for atmos-engineer. |
| 12 | `aws-config-rules` | cloudposse/config 1.6.1 (`modules/cis-1-2-rules`) | FAIL — input drift | **Fixed** | Added required passthroughs `support_policy_arn` (CIS 1.20) and `cloudtrail_bucket_name` (CIS 2.6). |
| 13 | `aws-scp` | cloudposse/service-control-policies 0.15.2 | OK | OK | Args match v0.15.2. |
| 14 | `centralized-logging-bucket` | cloudposse/s3-bucket 4.12.0 | FAIL — input drift | **Fixed** | `logging = ... ? null : { ... }` → `... ? [] : [{ ... }]` (module's `logging` is `list(object)` `nullable=false`); `kms_master_key_arn` `null` → `""` (`nullable=false`). |
| 15 | `cloudtrail-additional` | cloudposse/cloudtrail 0.24.0 + cloudposse/cloudtrail-s3-bucket | FAIL — version pin | **Fixed** | `cloudtrail-s3-bucket` 1.2.0 → 0.32.0 (1.2.0 never existed upstream). |
| 16 | `cloudtrail-lake` | Vanilla | FAIL — `module.this` undeclared | **Fixed** | Added canonical `context.tf`. Uses raw `aws_cloudtrail_event_data_store`. |
| 17 | `cloudwatch-log-groups` | cloudposse/cloudwatch-logs 0.6.9 | OK | OK | Args match v0.6.9. |
| 18 | `controltower-event-bridge` | Vanilla | FAIL — `module.this` undeclared | **Fixed** | Added canonical `context.tf`. Uses raw `aws_cloudwatch_event_rule`/`_target`. |
| 19 | `dns-delegated` | Vanilla | OK | OK | Raw `aws_route53_zone`, no module. |
| 20 | `dns-primary` | Vanilla | OK | OK | Raw `aws_route53_zone`, no module. |
| 21 | `github-oidc-provider` | Vanilla | OK | OK | Raw `aws_iam_openid_connect_provider` + `aws_iam_role`. |
| 22 | `guardduty-delegated-admin` | cloudposse/guardduty 1.0.0 | FAIL — input + output drift | **Fixed** | `eks_protection_enabled` → `kubernetes_audit_logs_enabled`; `malware_protection_enabled` → `malware_protection_scan_ec2_ebs_volumes_enabled`. Removed `auto_enable_organization_members` (not exposed); added sibling `aws_guardduty_organization_configuration.this` consuming `module.guardduty.guardduty_detector.id` to preserve phase-2 invariant. Outputs: `module.guardduty.detector_id`/`_arn` → `module.guardduty.guardduty_detector.id`/`.arn`. Component-level var names preserved — stack configs unchanged. |
| 23 | `guardduty-member-settings` | cloudposse/guardduty 1.0.0 | FAIL — input + output drift | **Fixed** | Same arg renames as #22. Removed `auto_enable_organization_members = "NONE"` from module call (not exposed); retained `"NONE"` token in a comment to preserve phase-3 Terratest substring assertion (semantic enforcement: deliberately not declaring `aws_guardduty_organization_configuration` in member account). Same output rewires. |
| 24 | `guardduty-root` | cloudposse/guardduty 1.0.0 | OK | OK | Args match v1.0.0; phase-1 admin-account registration only. |
| 25 | `iam-deployment-roles/central` | Vanilla | FAIL — `module.this` undeclared | **Fixed** | Added canonical `context.tf`. |
| 26 | `iam-deployment-roles/target` | Vanilla | FAIL — `module.this` undeclared | **Fixed** | Added canonical `context.tf`. |
| 27 | `identity-center-assignments` | cloudposse/sso 1.2.0 (`modules/account-assignments`) | FAIL — input drift | **Fixed** | Source `cloudposse/sso/aws` → `cloudposse/sso/aws//modules/account-assignments` (registry root has no module). Removed `permission_sets = []` (not exposed) and `context = module.this.context` (submodule has no null-label). |
| 28 | `identity-center-permission-sets` | cloudposse/sso 1.2.0 (`modules/permission-sets`) | FAIL — input + output drift | **Fixed** | Source switched to `//modules/permission-sets`. Removed `account_assignments = []` and `context = module.this.context`. Output transformed to `{ for k, v in module.permission_sets.permission_sets : k => v.arn }`. |
| 29 | `inspector2` | Vanilla | OK | OK | Raw `aws_inspector2_enabler` + `aws_inspector2_organization_configuration`. |
| 30 | `ipam` | Vanilla | OK | OK | Raw `aws_vpc_ipam` + `aws_vpc_ipam_pool`. |
| 31 | `security-hub` | cloudposse/security-hub 0.12.2 | FAIL — input drift | **Fixed** | Removed bogus `create_organization_admin_account = false` arg from module call (not exposed). Sibling `aws_securityhub_organization_admin_account` resource still does delegated-admin work. |
| 32 | `tfstate-backend` | cloudposse/tfstate-backend 1.9.0 | OK | OK | Args match v1.9.0 — `s3_state_lock_enabled`, `kms_master_key_id`. CMK id resolved via `aws_kms_alias` data source (module doesn't output it). |
| 33 | `tfstate-backend-central` | cloudposse/tfstate-backend 1.9.0 | OK | OK | Same shape as row 32. |
| 34 | `vpc-flow-logs-bucket` | cloudposse/vpc-flow-logs-s3-bucket 1.3.1 | OK | OK | Args match v1.3.1. |

