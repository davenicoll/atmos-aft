# tests

Four-tier test harness for atmos-aft. Each tier runs independently; the
`static` and `opa` tiers are fast enough to gate every PR, `act` is a
workflow-syntax smoke, and `terratest` is opt-in per PR (default on main).

## Tiers

| Tier | Scope | Runtime | Blocking on PR |
|---|---|---|---|
| **static** | `atmos validate stacks` + `atmos describe stacks` + `terraform fmt -check` + per-component `terraform validate` + `tflint` + per-component `terraform test` (any `components/terraform/*/tests/*.tftest.hcl`) | ~3–6 min | yes |
| **opa** | Rego unit tests (`opa test`) + `conftest test` against the fleet's resolved stacks | <1 min | yes |
| **act** | `act --list` + `act --dryrun` for each entry workflow (matrix); fixture-driven | ~1–3 min | yes |
| **terratest** | `go test ./...` under `tests/terratest/`; build-tagged for live-AWS suites. Legacy - prefer `terraform test` (`.tftest.hcl`) for new coverage | 15–60 min | opt-in |

All tiers orchestrated by `.github/workflows/ci-tests.yaml`.

## Running locally

```bash
make test-static       # fast, no network
make test-opa          # fast, no AWS
make test-act          # needs docker + act
make test-terratest    # needs go 1.22; set TT_TAGS=e2e for live-AWS
make test-all          # all four tiers
make lint              # static + opa only
```

## Directory layout

```
tests/
├── act/
│   ├── .actrc                       # act config (images, arch pins)
│   ├── README.md
│   └── events/                      # per-workflow event fixtures
├── opa/
│   ├── README.md
│   ├── forbidden_components_test.rego
│   ├── guardduty_phase_ordering_test.rego
│   ├── naming_test.rego
│   └── required_ct_flags_test.rego  # fixtures are inline via `with input as {...}`
├── bootstrap/
│   ├── golden/                      # expected output for the bootstrap dry-run
│   ├── answers.yaml                 # non-interactive answers fixture
│   └── test_dry_run.sh
├── terratest/
│   ├── go.mod
│   ├── helpers/atmos.go             # shared: RepoRoot, DescribeComponent, etc.
│   └── *_test.go                    # legacy - prefer .tftest.hcl below
└── README.md (this file)

components/terraform/<name>/tests/   # native `terraform test` (.tftest.hcl)
                                     # - preferred home for new component coverage
                                     # - runs in CI as part of the static tier
```

## What each tier catches

- **static**: typos in stack YAML, missing imports, invalid Terraform, style
  drift. Runs against every PR; cheap.
- **opa**: forbidden-component attempts, missing CT-compat flags, GuardDuty
  phase-ordering violations, naming convention. Policies live in
  `.github/policies/`, exercised by `_test.rego` files under `tests/opa/`.
- **act**: workflow YAML that won't parse, composite-action wiring errors,
  broken step conditionals. `act --dryrun` evaluates the step graph without
  actually executing steps. Does NOT exercise OIDC, AWS STS, concurrency
  groups, or environment protections - those only run in real GHA.
- **terratest**: component-level behaviour that static analysis misses.
  Tagged `e2e` tests hit real AWS via localstack where supported or
  `//go:build e2e` otherwise. Default (untagged) tests run `atmos describe`
  + `terraform init/validate` assertions without touching AWS.

## Live-AWS Terratest

Use build tags to gate expensive tests:

```go
//go:build e2e

package mycomponent_test

import "testing"

func TestLiveProvision(t *testing.T) {
    // ... uses AWS STS
}
```

Then run with:

```bash
TT_TAGS=e2e make test-terratest
```

Without the tag, the file is excluded at compile time - the default
`make test-terratest` stays local-only.

## Adding a new test

| You added… | …write a test under | Example |
|---|---|---|
| A Rego policy | `tests/opa/<policy>_test.rego` | `forbidden_components_test.rego` |
| A Terraform component | `components/terraform/<name>/tests/*.tftest.hcl` (preferred) | `aws-config-rules/tests/skip_flag.tftest.hcl` |
| A component behaviour needing live AWS | `tests/terratest/<component>_test.go` with `//go:build e2e` | `target_role_chain_live_test.go` |
| An entry workflow | `tests/act/events/<workflow-name>.json` | synthetic GitHub webhook payload |
| A composite action | inside a test workflow in `tests/act/` | wire via `act` matrix |

## Writing `.tftest.hcl` for a component

Native `terraform test` (plan-only) is the preferred unit-test harness.
Co-located with the component, no Go toolchain, no AWS credentials.

```hcl
# components/terraform/<name>/tests/<topic>.tftest.hcl

# Option A - pure mock (works when no aws_iam_policy_document or other
# compute-only data source is under assertion):
mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "us-east-1", region = "us-east-1" }
  }
}

# Option B - real provider with STS preflight skipped (required when your
# assertions read data.aws_iam_policy_document.json or similar):
# provider "aws" {
#   region                      = "us-east-1"
#   skip_credentials_validation = true
#   skip_metadata_api_check     = true
#   skip_requesting_account_id  = true
#   access_key                  = "test"
#   secret_key                  = "test"
# }

variables {
  region    = "us-east-1"
  namespace = "test"
  stage     = "test"
  name      = "<component-name>"
  # ...required inputs
}

run "descriptive_case_name" {
  command = plan

  variables { /* per-case overrides */ }

  assert {
    condition     = <expression against plan state>
    error_message = "<what the test is guarding against>"
  }
}
```

Run locally: `cd components/terraform/<name> && terraform init -backend=false && terraform test`. Or across all components: `make tf-test`.

## CI workflow inputs

`ci-tests.yaml` accepts two knobs on `workflow_dispatch`:

- `run_terratest` (bool, default `false`) - force the Terratest tier even
  outside a push to main.

Plus two repo-var overrides consumed at runtime:

- `RUN_TERRATEST_ON_PR` (`'true'` to opt every PR into Terratest).
- `TT_ENABLE_TAGS` (comma-separated tags to enable, e.g. `e2e`).
