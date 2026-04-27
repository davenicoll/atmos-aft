# publish-status

Write account provisioning status and audit-trail metadata to SSM under
`/aft/account/<name>/`. Called at the end of every provisioning phase,
customization step, and destroy finalization.

Implements `gha-design.md` §5.2 and §7.4.

## Usage

```yaml
- uses: ./.github/actions/publish-status
  with:
    account_name: core-audit
    status: baseline-deployed
    stack: core-use1-prod
```

With extras:

```yaml
- uses: ./.github/actions/publish-status
  with:
    account_name: core-audit
    status: destroyed
    extra: |
      destroyed_at=2026-04-20T12:34:56Z
      service_catalog_record_id=rec-xyz
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `account_name` | yes | - | Logical account name used as the SSM path segment. |
| `status` | yes | - | Status value (see allowed list below). |
| `stack` | no | - | Atmos stack name. Written to `/aft/account/<n>/stack`. |
| `extra` | no | - | Newline-separated `key=value` pairs written under the prefix. |
| `region` | no | `$AWS_REGION` | SSM region. |

### Allowed status values

`provisioning`, `baseline-deployed`, `customized`, `drift`, `failed`,
`closing`, `destroyed`, `destroy-stuck`, `ct-confirmed`.

## Outputs

| Name | Description |
|---|---|
| `prefix` | SSM prefix that was written to (`/aft/account/<name>`). |

## Parameters always written

- `/aft/account/<n>/status`
- `/aft/account/<n>/status-updated-at` - ISO-8601 UTC.
- `/aft/account/<n>/triggered_by_sha` - `github.sha`.
- `/aft/account/<n>/triggered_by_commit_author` - `head_commit.author.email`, falling back to `github.actor`.
- `/aft/account/<n>/last-run-id` - `github.run_id`.
- `/aft/account/<n>/last-workflow` - `github.workflow`.

`triggered_by_*` preserves the original merging human when the workflow was
dispatched by `github-actions[bot]` via the default `GITHUB_TOKEN`, per
§5.2.

## Requirements

AWS credentials configured with `ssm:PutParameter` on `/aft/account/*`.
