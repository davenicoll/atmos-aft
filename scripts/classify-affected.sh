#!/usr/bin/env bash
# Partition `atmos describe affected` JSON into push-main routing buckets.
# Usage: classify-affected.sh [JSON] ; reads stdin if no arg. Emits
# key=value lines (new_stacks, destroyed_stacks, has_customizations) for
# $GITHUB_OUTPUT.
#
# INVARIANT: `new_stacks`, `destroyed_stacks`, and `modified_stacks` are
# intended to be DISJOINT - a given stack must land in at most one bucket
# per run. The downstream routing logic assumes this (e.g. it will not try
# to both create and destroy the same stack). If you add a new bucket or
# change the filters below, ensure no stack can match more than one of the
# selectors; otherwise the workflow will double-dispatch and may deadlock
# on resource ownership. Add an explicit guard if you introduce overlap.

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
