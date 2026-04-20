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
| `component` | no | — | Optional component name. When set, uses `atmos describe component`. |

## Outputs

| Name | Description |
|---|---|
| `account_id` | Account ID from `vars.account_id`. |
| `region` | AWS region from `vars.region`. |
| `target_role_arn` | `arn:aws:iam::<account_id>:role/AtmosDeploymentRole`. |
| `stack_name` | Echo of the input stack. |

## Requirements

- Atmos and `jq` on PATH. Run `setup-atmos` first.
- No AWS credentials needed.
