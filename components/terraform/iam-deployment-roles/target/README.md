# iam-deployment-roles/target

Stamps `AtmosDeploymentRole` + `AtmosDeploymentRole-ReadOnly` into a target account. Applied once per account during bootstrap or account provisioning — the component runs from aft-mgmt under the central deployment identity, but creates IAM in the target account via the `aws.target` provider alias.

Source of truth: `docs/architecture/gha-design.md` §4.6 (role placement matrix) and `docs/architecture/mapping.md` §5.4 (bootstrap identity chain).

## Roles created (in the target account)

| Role | Trust | Policy |
|------|-------|--------|
| `AtmosDeploymentRole` | `arn:aws:iam::<aft-mgmt>:role/AtmosCentralDeploymentRole` (+ optional `sts:ExternalId`) | `AdministratorAccess` |
| `AtmosDeploymentRole-ReadOnly` | `arn:aws:iam::<aft-mgmt>:role/AtmosPlanOnlyRole` (+ optional `sts:ExternalId`) | `ReadOnlyAccess` + `organizations:Describe*/List*` inline |

Both trust policies include an `aws:userid` StringLike match on `AROA*:atmos-*` to enforce that assumptions carry an Atmos-tagged session name.

## ExternalId guardrail

`sts:ExternalId` is **required** for the four CT-core account classes (`ct-mgmt`, `aft-mgmt`, `audit`, `log-archive`) and **omitted** for `vended`. Rationale: the CT-core accounts predate Atmos, so a second factor on assume-role mitigates the residual risk that an unrelated caller in aft-mgmt learns the role ARN. Vended accounts are fresh at stamping time; the account ID itself is the uniqueness signal.

The external ID is a static per-org UUID stored in GHA vars as `ATMOS_EXTERNAL_ID` and passed to this component via the `atmos_external_id` variable.

## Bootstrap identity path

This component runs **before** `AtmosDeploymentRole` exists in the target. The `aws.target` provider alias is rendered by Atmos to use a bootstrap identity:

- Vended accounts: `AWSControlTowerExecution` (stamped by CT Account Factory)
- CT-core accounts: `OrganizationAccountAccessRole` (stamped by Organizations)

Selected via `ATMOS_AUTH_IDENTITY=target-bootstrap` in the calling workflow (`_bootstrap-target.yaml`). The `target-bootstrap` identity in `atmos.yaml` templates the assumed role as `arn:aws:iam::{{ .vars.account_id }}:role/{{ .vars.bootstrap_role | default "AWSControlTowerExecution" }}`, so the **stack YAML for each account class sets `vars.bootstrap_role`** — omit it for vended (default `AWSControlTowerExecution`), set it to `OrganizationAccountAccessRole` for the four CT-core classes. The component itself does not consume `bootstrap_role`; it's purely an auth-chain input. After this component applies, every subsequent component in the stack uses the default `target` identity (which assumes `AtmosDeploymentRole`).

## Inputs

- `region`
- `aft_mgmt_account_id` — who hosts `AtmosCentralDeploymentRole` / `AtmosPlanOnlyRole`
- `account_class` — `ct-mgmt` | `aft-mgmt` | `audit` | `log-archive` | `vended`
- `atmos_external_id` — required for CT-core classes, empty for `vended`
- `max_session_duration` — default 3600

## Outputs

- `deployment_role_arn`
- `readonly_role_arn`
- `account_class` (echo)
- `external_id_required` (boolean)
