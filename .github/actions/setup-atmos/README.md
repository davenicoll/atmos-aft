# setup-atmos

Installs Atmos CLI and Terraform at pinned versions, restores the Atmos +
`.terraform` cache, and seeds `ATMOS_*` environment variables for subsequent
steps.

Implements `gha-design.md` §7.1.

## Usage

```yaml
- uses: ./.github/actions/setup-atmos
```

With explicit versions:

```yaml
- uses: ./.github/actions/setup-atmos
  with:
    atmos_version: 1.100.0
    terraform_version: 1.9.8
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `atmos_version` | no | read from `atmos.yaml` | Atmos CLI version. |
| `terraform_version` | no | read from `atmos.yaml` | Terraform version. |
| `atmos_config_path` | no | `atmos.yaml` | Path to `atmos.yaml`. |
| `cache` | no | `true` | Whether to restore/save the Atmos + `.terraform` cache. |

## Outputs

| Name | Description |
|---|---|
| `atmos_version` | Atmos CLI version that was installed. |
| `terraform_version` | Terraform version that was installed. |

## Resolution order

For both `atmos_version` and `terraform_version`:

1. Explicit action input.
2. Value at `integrations.atmos.version` (Atmos) or `components.terraform.version` (Terraform) in `atmos.yaml`.
3. Built-in fallback.

## Environment variables set

- `ATMOS_BASE_PATH` — repo root.
- `ATMOS_LOGS_LEVEL=Info`.
- `ATMOS_CLI_CONFIG_PATH` — repo root.
