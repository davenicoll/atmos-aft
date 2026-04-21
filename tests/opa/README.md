# tests/opa

Rego unit tests for the policies under `.github/policies/`. This directory
holds the `_test.rego` files that exercise each rule with fixture inputs.

## Running

```bash
make test-opa
# same as: opa test .github/policies tests/opa -v
```

## Layout

```
tests/opa/
├── fixtures/                       # JSON fixtures for stack-shape inputs
├── forbidden_components_test.rego
├── guardduty_phase_ordering_test.rego
├── naming_test.rego
└── required_ct_flags_test.rego
```

Each `_test.rego` file:

1. Loads a fixture from `fixtures/<scenario>.json`.
2. Asserts against the `deny[_]` rule output shape — exactly zero violations
   for valid inputs, at least one for invalid ones.
3. Covers both the "allowed" and "denied" branch of every rule.

Wired into `.github/workflows/ci-tests.yaml` tier 2 (OPA). A single failing
`opa test` blocks the PR.
