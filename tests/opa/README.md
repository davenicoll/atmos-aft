# tests/opa

Rego unit tests for the policies under `.github/policies/`. This directory
holds the `_test.rego` files that exercise each rule with inline fixtures.

## Running

```bash
make test-opa
# same as: opa test .github/policies tests/opa -v
```

## Layout

```
tests/opa/
├── forbidden_components_test.rego
├── guardduty_phase_ordering_test.rego
├── naming_test.rego
└── required_ct_flags_test.rego
```

Fixtures are inline in each `_test.rego` file as Rego object literals passed
via `with input as {...}` - no JSON files on disk. Keeping fixtures colocated
with their assertions makes each test self-contained and avoids the
fixture-file drift that plagues larger policy suites.

Each `_test.rego` file:

1. Constructs an `input` that mimics the shape of `atmos describe stacks
   --format json` (map of `stack_name` → stack object).
2. Asserts against the `deny[_]` rule output shape - exactly zero violations
   for valid inputs, at least one for invalid ones.
3. Covers both the "allowed" and "denied" branch of every rule.

Wired into `.github/workflows/ci-tests.yaml` tier 2 (OPA). A single failing
`opa test` blocks the PR.
