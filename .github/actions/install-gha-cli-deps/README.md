# install-gha-cli-deps

Install ancillary CLIs used across workflows — `jq`, `yq`, `conftest`,
`opa`, and optional `gh` extensions — at pinned versions.

Implements `gha-design.md` §7.6.

`aws`, `terraform`, `atmos`, and `gh` are not installed here: the first
two come pre-installed on `ubuntu-latest` runners (and `terraform` and
`atmos` are installed at pinned versions by `setup-atmos`); `gh` is
pre-installed on hosted runners.

## Usage

```yaml
- uses: ./.github/actions/install-gha-cli-deps
```

With overrides and gh extensions:

```yaml
- uses: ./.github/actions/install-gha-cli-deps
  with:
    yq_version: 4.44.3
    conftest_version: 0.56.0
    opa_version: 0.68.0
    gh_extensions: cli/gh-dash dlvhdr/gh-prs
```

## Inputs

| Name | Required | Default | Description |
|---|---|---|---|
| `yq_version` | no | `4.44.3` | yq version. |
| `conftest_version` | no | `0.56.0` | Conftest version. |
| `opa_version` | no | `0.68.0` | OPA version. |
| `install_jq` | no | `true` | Install `jq` via apt if missing. |
| `gh_extensions` | no | — | Space-separated `owner/repo` gh extensions. |

## Behaviour

- Skips each install when the requested version is already present.
- Places binaries in `/usr/local/bin` so they are on `PATH` for later steps.
- `gh extension install` uses `github.token` — the job needs no extra
  permissions for public extensions.
