# example-accounts-single

Worked example of the single-account topology (`separate_aft_mgmt_account=false`).
Mirrors `example-accounts/` but collapses the AFT management account into the
Control Tower management account — so the `aft/aft-mgmt` stack disappears and
`core/ct-mgmt` carries both the CT-core catalogs and the AFT-central catalogs
(`tfstate-backend-central`, `iam-deployment-roles/central`, `github-oidc-provider`,
`controltower-event-bridge`).

## Why it's excluded from default discovery

Stack keys derive from `{tenant}-{environment}-{stage}` — the same keys
`example-accounts/` produces. To avoid a name collision in `atmos describe
stacks`, this directory is listed under `excluded_paths` in `atmos.yaml`.
It is a reference, not a runtime peer.

## Exercising it

To validate this tree alongside (or instead of) `example-accounts/`, swap the
`stacks.included_paths`/`excluded_paths` in `atmos.yaml` or point Atmos at a
copy of the config with that swap applied (e.g. via `ATMOS_CLI_CONFIG_PATH`).
