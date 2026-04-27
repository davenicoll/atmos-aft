# iam-deployment-roles/central

Three IAM roles in the aft-mgmt account that form the central control plane for every Atmos deployment. Applied during `bootstrap.yaml` step 3 under the bootstrap access-key identity.

Source of truth: `docs/architecture/atmos-model.md` §9.3.2 and `docs/architecture/gha-design.md` §4.6.

## Roles created

| Role | Trust | Used for |
|------|-------|----------|
| `AtmosCentralDeploymentRole` | GitHub OIDC pinned to `refs/heads/main` + protected environments | First hop after OIDC for every deploy/destroy workflow. Holds `AdministratorAccess` + `sts:AssumeRole` on target-account roles. |
| `AtmosPlanOnlyRole` | GitHub OIDC pinned to `pull_request` | PR plan jobs. Read-only state + assume `*:role/AtmosDeploymentRole-ReadOnly` in targets. |
| `AtmosReadAllStateRole` | `AtmosCentralDeploymentRole` (same-account) | Cross-account drift-summary aggregation. Permissions boundary enforces read-only. |

## Trust pinning

The deploy path pins OIDC `sub` to four claims: `refs/heads/main` plus three environment claims (`aft-mgmt`, `vended`, `core`) - matching the environments declared in `gha-design.md` §10.2. Plan-only pins to `pull_request` and is fully distinct; a PR workflow cannot accidentally assume the deploy role.

## Cross-references

- `AtmosReadAllStateRole` ARN is published as an output and must be referenced by every target-account `tfstate-backend` component's KMS key policy (§9.3.2 `AllowReadAllStateRoleDecryptOnly`) and S3 bucket policy (`AllowReadAllStateRoleRead`). The per-account `iam-roles-target-account` component consumes it via Atmos remote-state.
- `AtmosCentralDeploymentRole`'s assume-role policy lists `*:role/AWSControlTowerExecution` and `*:role/OrganizationAccountAccessRole` as assumable targets - this is what lets the bootstrap identity reach into newly vended accounts before `AtmosDeploymentRole` exists there (see `mapping.md` §5.4).

## Inputs

- `region`
- `github_org`, `github_repo` - pin the OIDC `sub` claim
- `github_oidc_provider_arn` - created by the `github-oidc-provider` component, consumed here via stack `!terraform.output`
- `max_session_duration` - default 3600

## Outputs

- `central_role_arn`, `central_role_name`
- `plan_only_role_arn`
- `read_all_state_role_arn`

The `read_all_state_role_arn` output is the one every per-account `tfstate-backend` component and `iam-roles-target-account` component needs to pick up via remote-state.
