# configure-aws

Configure AWS credentials for Atmos runs, dispatching between OIDC (default)
and access-key (opt-in) modes, and seeding `ATMOS_AUTH_IDENTITY` for the
Terraform-level auth chain.

Implements `gha-design.md` §4.2 / §4.3 / §4.5 and §7.2.

## Usage

```yaml
- uses: ./.github/actions/configure-aws
  with:
    central_role_arn: ${{ vars.ATMOS_CENTRAL_ROLE_ARN }}
    region: ${{ vars.AWS_REGION }}
```

Bootstrap identity for a newly vended account (jobs 3 and 4 of
`provision-account.yaml`):

```yaml
- uses: ./.github/actions/configure-aws
  with:
    central_role_arn: ${{ vars.ATMOS_CENTRAL_ROLE_ARN }}
    region: ${{ vars.AWS_REGION }}
    identity: bootstrap
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `mode` | no | `$AFT_AUTH_MODE`, then `oidc` | Auth mode: `oidc` or `access_key`. Validated: only those two values accepted. |
| `central_role_arn` | yes | - | ARN of `AtmosCentralDeploymentRole`. Validated against `^arn:aws:iam::[0-9]{12}:role/.+`. |
| `target_role_arn` | no | - | When non-empty, exported as `TF_VAR_target_role_arn` so each component's provider `dynamic "assume_role"` block resolves to this role. Leave empty for components that stay in the central account. |
| `region` | yes | - | AWS region. |
| `role_session_name` | no | `atmos-<workflow>-<run_id>` (truncated to 64 chars) | STS role session name. Auto-truncated to the STS 64-char limit. |
| `identity` | no | `default` | Atmos auth identity: `default` (central → `AtmosDeploymentRole`) or `bootstrap` (central → `AWSControlTowerExecution`/`OrganizationAccountAccessRole`). Validated: only those two values accepted. |

## Outputs

| Name | Description |
|---|---|
| `account_id` | Account ID reported by `sts:GetCallerIdentity`. |
| `mode` | Resolved auth mode. |

## Validation

The action fails fast with a clear error when:
- `identity` is not `default` or `bootstrap`.
- `mode` is not `oidc` or `access_key`.
- `central_role_arn` does not match the standard IAM role ARN shape.

## Access-key mode

Reads `AFT_BOOTSTRAP_ACCESS_KEY_ID` and `AFT_BOOTSTRAP_SECRET_ACCESS_KEY`
from the environment, configures them as the base credentials, and then
chains to `central_role_arn` via `sts:AssumeRole`. The resulting session
credentials are written to `GITHUB_ENV` and masked in logs.

## Identity handling

`ATMOS_AUTH_IDENTITY` is set to the value of `identity` so Atmos's auth
chain (see `atmos.yaml` `auth:` section) picks the right second-hop role:

- `default` - central → `AtmosDeploymentRole` in the target account.
- `bootstrap` - central → `AWSControlTowerExecution` (vended accounts) or
  `OrganizationAccountAccessRole` (CT core accounts).
