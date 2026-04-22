#!/usr/bin/env bash
# Dry-runs `atmos bootstrap` against a pre-baked answers YAML and diffs every
# rendered block against tests/bootstrap/golden/<relative path>.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
GOLDEN="$HERE/golden"
PREFIX="stacks/orgs/acme/"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash "$REPO/scripts/bootstrap/run.sh" \
    --answers "$HERE/answers.yaml" --dry-run >"$tmp/out.txt"

awk -v dest="$tmp/rendered" -v prefix="$PREFIX" '
    /^--- / {
        if (out) close(out)
        rel=$2; sub("^" prefix, "", rel)
        out=dest "/" rel
        cmd="mkdir -p \"" out; sub("/[^/]*$","",cmd); cmd=cmd "\""; system(cmd)
        next
    }
    /^=== plan ===/ { if(out){close(out); out=""} next }
    out { print >> out }
' "$tmp/out.txt"

fail=0
while IFS= read -r g; do
    rel=${g#$GOLDEN/}
    got="$tmp/rendered/$rel"
    if [[ ! -f "$got" ]]; then
        echo "MISSING render: $rel" >&2
        fail=1
        continue
    fi
    if ! diff -u "$g" "$got"; then
        fail=1
    fi
done < <(find "$GOLDEN" -type f -name '*.yaml' | sort)

if [[ $fail -eq 0 ]]; then
    echo "bootstrap dry-run: all goldens match"
fi
exit $fail
