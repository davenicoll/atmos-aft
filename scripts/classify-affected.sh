#!/usr/bin/env bash
# Partition `atmos describe affected` JSON into push-main routing buckets.
# Usage: classify-affected.sh [JSON] ; reads stdin if no arg. Emits
# key=value lines (new_stacks, destroyed_stacks, has_customizations) for
# $GITHUB_OUTPUT.

set -euo pipefail

affected_json="${1:-$(cat)}"

new_stacks=$(jq -c '
  [ .[]
    | select(.component == "account-provisioning")
    | select(.affected == "stack.added" or .action == "added")
    | .stack
  ] | unique
' <<<"$affected_json")

destroyed_stacks=$(jq -c '
  [ .[]
    | select(.metadata.deleted == true)
    | .stack
  ] | unique
' <<<"$affected_json")

has_customizations=$(jq -r '
  [ .[] | select(.component | startswith("customizations/")) ] | length > 0
' <<<"$affected_json")

printf 'new_stacks=%s\n' "$new_stacks"
printf 'destroyed_stacks=%s\n' "$destroyed_stacks"
printf 'has_customizations=%s\n' "$has_customizations"
