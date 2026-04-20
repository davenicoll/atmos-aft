# tests/act

Local GitHub Actions runner harness using [nektos/act](https://github.com/nektos/act).

## Prerequisites

- `act` >= 0.2.60 (`brew install act`).
- Docker running locally.
- `.env.act` at the repo root with any dev-only overrides (gitignored).

## Running

```bash
# Dry-run every workflow — static syntax check.
make test-act

# Run a single entry workflow with a synthetic event fixture:
act pull_request \
  -W .github/workflows/pr.yaml \
  -e tests/act/events/pull_request.json
```

## Event fixtures

Event JSON files under `tests/act/events/` are consumed by the matrix in
`.github/workflows/ci-tests.yaml`. They are added alongside each entry
workflow as it lands (task #21). A fixture is a minimal GitHub webhook
payload stub — see the [webhook docs](https://docs.github.com/en/webhooks/webhook-events-and-payloads)
for schemas.

## What `act` does (and does not) cover

- **Covered.** Workflow parse errors, step ordering, conditional evaluation,
  composite-action wiring, env-var propagation.
- **Not covered.** OIDC federation (no AWS STS locally), `workflow_run`
  triggers across workflows, GHA concurrency groups, environment protections.
  Those live in task #25 review + production observation.

Use `act` as a fast syntax sanity check, not a substitute for running the
workflow in CI.
