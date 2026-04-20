#!/usr/bin/env bash
# Partition `atmos describe affected` JSON into the four push-main buckets.
# Input on stdin: JSON array from `atmos describe affected --format json`.
# Output on stdout: key=value lines suitable for appending to $GITHUB_OUTPUT.
#
#   new_stacks=<json-array>        stacks whose account-provisioning is newly added
#   destroyed_stacks=<json-array>  stacks marked metadata.deleted=true
#   has_customizations=<bool>      any affected component under customizations/*
#
# Consumed by .github/workflows/push-main.yaml route job.

set -euo pipefail

affected_json="${1:-$(cat)}"

# Newly added stacks: account-provisioning component added in this diff.
new_stacks=$(jq -c '
  [ .[]
    | select(.component == "account-provisioning")
    | select(.affected == "stack.added" or .action == "added")
    | .stack
  ] | unique
' <<<"$affected_json")

# Tombstoned stacks: metadata.deleted flipped true.
destroyed_stacks=$(jq -c '
  [ .[]
    | select(.metadata.deleted == true)
    | .stack
  ] | unique
' <<<"$affected_json")

# Any customizations/* instance affected?
has_customizations=$(jq -r '
  [ .[] | select(.component | startswith("customizations/")) ] | length > 0
' <<<"$affected_json")

printf 'new_stacks=%s\n' "$new_stacks"
printf 'destroyed_stacks=%s\n' "$destroyed_stacks"
printf 'has_customizations=%s\n' "$has_customizations"
