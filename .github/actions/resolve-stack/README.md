# resolve-stack

Resolve an Atmos stack to its account ID, region, target role ARN, and
canonical stack name. Called before `configure-aws` when a workflow needs
cross-account context.

Implements `gha-design.md` §7.3.

## Usage

```yaml
- uses: ./.github/actions/setup-atmos
- id: ctx
  uses: ./.github/actions/resolve-stack
  with:
    stack: core-use1-prod
- uses: ./.github/actions/configure-aws
  with:
    central_role_arn: ${{ vars.ATMOS_CENTRAL_ROLE_ARN }}
    region: ${{ steps.ctx.outputs.region }}
```

With a component (resolves catalog vars):

```yaml
- uses: ./.github/actions/resolve-stack
  with:
    stack: core-use1-prod
    component: vpc
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `stack` | yes | — | Atmos stack name. |
| `component` | no | — | Optional component name. When set, uses `atmos describe component` (which resolves catalog vars); otherwise `atmos describe stacks` reads stack-level vars only. |
| `target_role_name` | no | `AtmosDeploymentRole` | Role name used when computing `target_role_arn`. Set to `AtmosDeploymentRoleReadOnly` for plan-only invocations (see `pr.yaml`, `drift-detection.yaml`). |
| `require_target` | no | `true` | When `true`, fail if `vars.account_id` cannot be resolved. Set to `false` for central-only components (`iam-deployment-roles/central`, `tfstate-backend-central`, `github-oidc-provider`). With `false`, `account_id`, `account_name`, and `target_role_arn` are emitted empty. |

## Outputs

| Name | Description |
|---|---|
| `account_id` | Account ID from `vars.account_id` (falls back to `vars.tenant_account_id`). Empty for central-only stacks when `require_target=false`. |
| `account_name` | Logical account name from `vars.account_name` (e.g. `plat-dev`). Used as the `/aft/account/<name>/` SSM path segment. Empty for central-only stacks. |
| `account_email` | Account email from `vars.account_email`. Populated for leaf stacks that wrap `account-provisioning`. Used by destroy-account for the 7-day cooldown guard. |
| `account_class` | Account class from `vars.account_class` (e.g. `vended`, `ct-mgmt`, `aft-mgmt`, `audit`, `log-archive`). |
| `bootstrap_role` | Bootstrap-identity role name from `vars.bootstrap_role`, pinned per account class by `stacks/catalog/account-classes/*.yaml`. Typically `AWSControlTowerExecution` (vended) or `OrganizationAccountAccessRole` (CT core). Empty if unset. |
| `region` | AWS region from `vars.region`. |
| `target_role_arn` | `arn:aws:iam::<account_id>:role/<target_role_name>`. Empty for central-only stacks. |
| `stack_name` | Canonical stack name (echo of input). |

## Requirements

- Atmos and `jq` on PATH. Run `setup-atmos` first.
- No AWS credentials needed.
