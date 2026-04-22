#!/usr/bin/env bash
# Dry-runs `atmos bootstrap` A→D against a pre-baked answers YAML, diffs every
# rendered Phase-B block against tests/bootstrap/golden/, and asserts the
# Phase-C/D DRY-command lines contain the expected aws/atmos/gh calls.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOLDEN="$HERE/golden"
PREFIX="stacks/orgs/acme/"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$REPO/scripts/bootstrap/run.sh" \
    --answers "$HERE/answers.yaml" --dry-run --yes >"$tmp/out.txt"

# Split Phase B rendered blocks into $tmp/rendered/<rel>.
awk -v dest="$tmp/rendered" -v prefix="$PREFIX" '
    /^--- / {
        if (out) close(out)
        rel=$2; sub("^" prefix, "", rel)
        out=dest "/" rel
        cmd="mkdir -p \"" out; sub("/[^/]*$","",cmd); cmd=cmd "\""; system(cmd)
        next
    }
    /^=== plan ===/ { if(out){close(out); out=""} next }
    /^phase C:/ { if(out){close(out); out=""} next }
    /^DRY:/ { if(out){close(out); out=""} next }
    /^bootstrap: done$/ { if(out){close(out); out=""} next }
    out { print >> out }
' "$tmp/out.txt"

fail=0

# Phase B: golden diff.
while IFS= read -r g; do
    rel=${g#$GOLDEN/}
    got="$tmp/rendered/$rel"
    if [[ ! -f "$got" ]]; then echo "MISSING render: $rel" >&2; fail=1; continue; fi
    diff -u "$g" "$got" || fail=1
done < <(find "$GOLDEN" -type f -name '*.yaml' | sort)

# Phase C: expected DRY commands.
expect_c=(
    "DRY: atmos terraform apply github-oidc-provider -s aft-gbl-mgmt --auto-approve"
    "DRY: atmos terraform apply iam-deployment-roles/central -s aft-gbl-mgmt --auto-approve"
    "DRY: atmos terraform init tfstate-backend-central -s aft-gbl-mgmt -- -reconfigure -migrate-state"
    "DRY: atmos terraform apply tfstate-backend-central -s aft-gbl-mgmt --auto-approve"
)
for line in "${expect_c[@]}"; do
    if ! grep -qF "$line" "$tmp/out.txt"; then
        echo "MISSING phase-C line: $line" >&2; fail=1
    fi
done

# Phase D: expected gh dispatch.
expect_d="DRY: gh workflow run bootstrap.yaml -f aft_mgmt_account_id=222222222222 -f aft_mgmt_region=us-east-1 -f separate_aft_mgmt_account=true -f terraform_distribution=oss"
if ! grep -qF "$expect_d" "$tmp/out.txt"; then
    echo "MISSING phase-D line: $expect_d" >&2; fail=1
fi

# Phase-subset flag: --phase D should emit only Phase D.
bash "$REPO/scripts/bootstrap/run.sh" \
    --answers "$HERE/answers.yaml" --dry-run --yes --phase D >"$tmp/phase_d.txt"
if grep -qE '^--- |phase C:' "$tmp/phase_d.txt"; then
    echo "--phase D leaked earlier phases" >&2; fail=1
fi
grep -qF "$expect_d" "$tmp/phase_d.txt" || { echo "--phase D did not emit Phase D dispatch" >&2; fail=1; }

if [[ $fail -eq 0 ]]; then echo "bootstrap dry-run: all checks pass"; fi
exit $fail
