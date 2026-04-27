# cloudtrail-lake

CloudTrail Lake event data store for the audit account. Replaces AFT's `aft-request-audit` DynamoDB table (see `docs/architecture/mapping.md` §4.1) - the ledger of every AWS API call relevant to account provisioning and organization management.

Configured for 7-year retention, termination protection on, four event sources (`controltower`, `organizations`, `servicecatalog`, `sts`).

## What it creates

- One `aws_cloudtrail_event_data_store` in the audit account
- `TerminationProtectionEnabled = true`
- `RetentionPeriod = 2557` (~7 years; AWS max is 3653/~10y)
- Advanced event selector filtering to `Management` events from the four sources
- Single-region by default; flip `multi_region_enabled` if DR requires cross-region capture

## Stack placement

Lives under `stacks/orgs/<org>/core/audit/<region>.yaml`. One instance per audit account (single-region).

## Query pattern

Drift-detection and incident-response workflows query the store via `aws cloudtrail start-query` with SQL like:

```sql
SELECT eventTime, userIdentity.arn, eventName, requestParameters
FROM <event_data_store_id>
WHERE eventSource = 'servicecatalog.amazonaws.com'
  AND eventName = 'ProvisionProduct'
  AND requestParameters LIKE '%<account-name>%'
ORDER BY eventTime DESC
LIMIT 100
```

## Inputs

- `region`
- `retention_days` (default 2557)
- `multi_region_enabled` (default false)
- `kms_key_id` (optional CMK; null uses AWS-managed key)

## Outputs

- `event_data_store_arn`, `event_data_store_id`, `event_data_store_name`
