#!/usr/bin/env bash
# Minimal go-template subset renderer. Reads template on stdin, answer
# key=value lines via ANSWERS env (newline-separated), emits rendered text.
# Supports {{ .key }} substitution only — branching is pre-resolved by the
# caller (see run.sh). gomplate is used when present for fidelity; otherwise
# we fall back to this renderer.
set -euo pipefail

if command -v gomplate >/dev/null 2>&1; then
    # Build a datasource from ANSWERS (key=value per line) as JSON.
    json=$(awk -F= 'BEGIN{print "{"} NR>1{printf ","} {key=$1; $1=""; sub(/^=/,""); gsub(/"/,"\\\""); printf "\"%s\":\"%s\"", key, $0} END{print "}"}' <<<"${ANSWERS}")
    exec gomplate --context ".=stdin:?type=application/json" <<<"$json" --in "$(cat)"
fi

tmpl=$(cat)
while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    # Escape &, / and | in value for sed.
    esc=$(printf '%s' "$v" | sed -e 's/[\/&|]/\\&/g')
    tmpl=$(printf '%s' "$tmpl" | sed -E "s|\\{\\{[[:space:]]*\\.${k}[[:space:]]*\\}\\}|${esc}|g")
done <<<"${ANSWERS}"
printf '%s\n' "$tmpl"
