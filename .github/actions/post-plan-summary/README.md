# post-plan-summary

Render an `atmos terraform plan` output into `$GITHUB_STEP_SUMMARY` and a
sticky PR comment. Optionally persists the planfile via
`cloudposse/github-action-terraform-plan-storage` for a later apply.

Implements `gha-design.md` §7.5.

## Usage

```yaml
- uses: ./.github/actions/setup-atmos
- name: Plan
  run: atmos terraform plan vpc -s core-use1-prod -out plan.bin
  working-directory: components/terraform/vpc
- uses: ./.github/actions/post-plan-summary
  with:
    plan_file: plan.bin
    stack: core-use1-prod
    component: vpc
    working_directory: components/terraform/vpc
```

With cross-workflow plan persistence:

```yaml
- uses: ./.github/actions/post-plan-summary
  with:
    plan_file: plan.bin
    stack: core-use1-prod
    component: vpc
    persist: "true"
    plan_storage_bucket: ${{ vars.PLAN_STORAGE_BUCKET }}
    plan_storage_table: ${{ vars.PLAN_STORAGE_TABLE }}
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `plan_file` | yes | — | Path to the Terraform planfile. |
| `stack` | yes | — | Atmos stack name. |
| `component` | yes | — | Atmos component name. |
| `working_directory` | no | `.` | Directory in which to run `terraform show`. |
| `persist` | no | `false` | Upload planfile via plan-storage action. |
| `plan_storage_bucket` | no | — | S3 bucket; required when `persist=true`. |
| `plan_storage_table` | no | — | DynamoDB table; required when `persist=true`. |
| `comment` | no | `true` | Post sticky PR comment on `pull_request` events. |

## Outputs

| Name | Description |
|---|---|
| `summary_path` | Absolute path to the rendered markdown summary file. |
| `has_changes` | `true` when the plan has add/change/destroy actions. |

## Requirements

- `terraform` and `jq` on PATH. Run `setup-atmos` first.
- For `persist=true`, AWS credentials with access to the plan-storage
  bucket and DynamoDB table.
- The sticky comment uses `header` = `plan-<component>-<stack>` so
  per-(component, stack) comments do not clobber each other.
