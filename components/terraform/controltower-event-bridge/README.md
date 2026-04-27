# controltower-event-bridge

Forwards Control Tower lifecycle events (`CreateManagedAccount`, `UpdateManagedAccount`, `RegisterOrganizationalUnit`) from the CT management account's default EventBridge bus to the atmos-aft repo's GitHub Actions via `repository_dispatch`.

Replaces the AFT `aft_controltower_events` DynamoDB table + stream-triggered Lambda (`mapping.md` §4.1).

Source of truth: `docs/architecture/gha-design.md` §5.12 (workflow side), §10.1 (auth + rotator), and `module-inventory.md` row 8.

## What it creates

1. **EventBridge rule** on the `default` bus matching `aws.controltower` service events with the three lifecycle event names.
2. **API destination + connection** pointing at `https://api.github.com/repos/<org>/<repo>/dispatches`, with `API_KEY` auth.
3. **Secrets Manager** - shape varies by `github_auth_mode`:
   - `app` (default): GitHub App PEM secret (long-lived) + installation-token secret (short-lived, auto-rotated), each under a distinct CMK.
   - `pat`: one fine-grained PAT secret (manual rotation every 90 days).
4. **Rotator Lambda** (app mode only): runs every 30 min, mints installation tokens from the PEM, writes to the token secret. IAM scoped per `gha-design.md` §10.1 - no wildcards, Decrypt only on PEM CMK, Encrypt only on token CMK (can write tokens, can't read its own output).
5. **SQS DLQ** (14-day retention) for API-destination delivery failures, with a bucket-not-empty alarm wired to SNS.
6. **CloudWatch alarms** on rotator errors + rotator staleness (reproducing SMR's out-of-the-box alerting without joining the SMR protocol).

## Auth mode selection

```yaml
components:
  terraform:
    controltower-event-bridge:
      vars:
        github_auth_mode: app              # or 'pat'
        github_app_id: "123456"            # app only
        github_app_installation_id: "78"   # app only
        rotator_zip_path: "artifacts/rotator.zip"  # app only
        alarm_notification_emails:
          - platform-ops@example.com
```

## Input-transformer mapping

The `CreateManagedAccount` event body is mapped into GitHub's `repository_dispatch` payload shape:

```json
{
  "event_type": "ct-CreateManagedAccount",
  "client_payload": {
    "event_id": "<EventBridge event ID>",
    "account_id": "...",
    "account_email": "...",
    "ou_name": "...",
    "ou_id": "...",
    "provisioned_product_id": "..."
  }
}
```

Consumed by `.github/workflows/ct-lifecycle-event.yaml`. The workflow's concurrency group is keyed on `event_id` so EventBridge's at-least-once delivery does not cause duplicate runs.

## Stack placement

One instance in `stacks/orgs/<org>/core/ct-mgmt/<region>.yaml`. Single region per org - CT is single-region for its event plane.

## Why the rotator is bespoke, not SMR

SMR's four-step `RotateSecret` protocol is designed for DB-credential atomic swaps (create new, test, promote, revoke old). Our case - "mint a short-lived token from a long-lived PEM" - has no atomic-swap concern; the old token expires on its own. Two CloudWatch alarms reproduce SMR's out-of-the-box alerting (error-count > 0; downstream token staleness > 35 min) without the protocol overhead.

## Why two CMKs in app mode

The rotator Lambda writes tokens but must never read its own output. Splitting the CMKs means the rotator's IAM can grant `kms:Encrypt`+`kms:GenerateDataKey` on the token CMK (write) and `kms:Decrypt` on the PEM CMK (read), with no overlap. A compromised rotator cannot replay the tokens it minted.

## Outputs

- `event_rule_arn`, `api_destination_arn`, `connection_arn`
- `dlq_arn`, `dlq_url`, `alarm_topic_arn`
- `rotator_function_arn` (null in PAT mode)
- `github_auth_mode` (echo)
