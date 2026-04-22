#!/usr/bin/env bash
# atmos bootstrap — slice 1: Phase A (gather) + Phase B (scaffold).
# No terraform/AWS calls. See docs/architecture/bootstrap.md when it lands.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
TPL="$HERE/templates"
QS="$HERE/questions.yaml"
RENDER="$HERE/render.sh"

ANSWERS_FILE=""
DRY_RUN=0
PRINT_QUESTIONS=0
SKIP_REMOTE=0

usage() {
    cat <<EOF
Usage: atmos bootstrap [--answers FILE] [--dry-run] [--print-questions] [--skip-remote]

Phase A gathers answers interactively (or via --answers).
Phase B scaffolds stack YAMLs and opens a PR (skipped with --skip-remote or --dry-run).
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --answers) ANSWERS_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --print-questions) PRINT_QUESTIONS=1; shift ;;
        --skip-remote) SKIP_REMOTE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ $PRINT_QUESTIONS -eq 1 ]]; then
    cat "$QS"
    exit 0
fi

die() { echo "bootstrap: $*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }
need yq

has_tty() { [[ -t 0 && -t 1 ]]; }
use_gum() { has_tty && command -v gum >/dev/null 2>&1; }

prompt_one() {
    local key="$1" msg="$2" default="${3:-}" choices="${4:-}"
    if [[ -n "$choices" ]]; then
        if use_gum; then
            gum choose --header "$msg" $choices
        else
            echo "$msg (options: $choices)" >&2
            read -r v
            printf '%s' "$v"
        fi
    else
        if use_gum; then
            gum input --header "$msg" --value "$default"
        else
            local suffix=""
            [[ -n "$default" ]] && suffix=" [$default]"
            printf '%s%s: ' "$msg" "$suffix" >&2
            read -r v
            [[ -z "$v" && -n "$default" ]] && v="$default"
            printf '%s' "$v"
        fi
    fi
}

default_github() {
    git -C "$REPO" remote get-url origin 2>/dev/null |
        sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##'
}

default_landing_zone() {
    command -v aws >/dev/null 2>&1 || return 0
    aws controltower list-landing-zones --query 'landingZones[0].arn' --output text 2>/dev/null |
        grep -E '^arn:' || true
}

# Phase A: answer collection. Stored as newline-delimited key=value pairs in ANSWERS_BUF.
ANSWERS_BUF=""
aput() { ANSWERS_BUF="${ANSWERS_BUF}${1}=${2}"$'\n'; }
aget() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<<"$ANSWERS_BUF"; }

if [[ -n "$ANSWERS_FILE" ]]; then
    [[ -r "$ANSWERS_FILE" ]] || die "answers file not readable: $ANSWERS_FILE"
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        aput "$k" "$v"
    done < <(yq -o=tsv '.answers | to_entries | map([.key, .value]) | .[]' "$ANSWERS_FILE")
else
    has_tty || die "no TTY for interactive prompts — use --answers FILE"
    gh_default=$(default_github || true)
    gh_org="${gh_default%%/*}"
    gh_repo="${gh_default##*/}"
    lz_default=$(default_landing_zone || true)
    count=$(yq '.questions | length' "$QS")
    for i in $(seq 0 $((count - 1))); do
        key=$(yq ".questions[$i].key" "$QS")
        msg=$(yq ".questions[$i].prompt" "$QS")
        choices=$(yq -r ".questions[$i].choices // [] | join(\" \")" "$QS")
        regex=$(yq -r ".questions[$i].validate // \"\"" "$QS")
        default=""
        case "$key" in
            github_org) default="$gh_org" ;;
            github_repo) default="$gh_repo" ;;
            ct_landing_zone_id) default="$lz_default" ;;
        esac
        while :; do
            val=$(prompt_one "$key" "$msg" "$default" "$choices")
            if [[ -n "$regex" && ! "$val" =~ $regex ]]; then
                echo "invalid — must match $regex" >&2
                continue
            fi
            [[ -n "$choices" ]] && { [[ " $choices " == *" $val "* ]] || { echo "invalid choice" >&2; continue; }; }
            break
        done
        aput "$key" "$val"
    done
fi

# Derived values consumed by templates.
topology_val=$(aget topology); [[ -z "$topology_val" ]] && topology_val="separate"
aput separate_aft_mgmt_account "$([[ "$topology_val" == "separate" ]] && echo true || echo false)"
aput example_tenant "plat"
aput example_tenant_title "Plat"

render_answers() { printf '%s' "$ANSWERS_BUF"; }

render_tpl() {
    local src="$1"
    ANSWERS="$(render_answers)" "$RENDER" <"$src"
}

ns="$(aget namespace)"
[[ -n "$ns" ]] || die "namespace is required"
out="$REPO/stacks/orgs/$ns"

# Idempotency check.
if [[ -f "$out/_defaults.yaml" ]]; then
    if [[ -n "$ANSWERS_FILE" || $DRY_RUN -eq 1 ]]; then
        echo "bootstrap: existing scaffold at $out — non-interactive rescaffold" >&2
    else
        echo "Existing scaffold at $out."
        choice=$(prompt_one rescaffold "Continue / rescaffold / abort" "continue" "continue rescaffold abort")
        case "$choice" in
            abort) exit 0 ;;
            rescaffold) rm -rf "$out" ;;
            *) ;;
        esac
    fi
fi

# Phase B: scaffold (or plan in dry-run).
plan_lines=()
render_to() {
    local src="$1" dst="$2"
    local rel="${dst#$REPO/}"
    plan_lines+=("write $rel")
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "--- $rel"
        render_tpl "$src"
    else
        mkdir -p "$(dirname "$dst")"
        render_tpl "$src" >"$dst"
    fi
}

render_to "$TPL/_defaults.yaml.tmpl"                    "$out/_defaults.yaml"
render_to "$TPL/core/ct-mgmt/_defaults.yaml.tmpl"       "$out/core/ct-mgmt/_defaults.yaml"
render_to "$TPL/core/aft-mgmt/_defaults.yaml.tmpl"      "$out/core/aft-mgmt/_defaults.yaml"
render_to "$TPL/core/audit/_defaults.yaml.tmpl"         "$out/core/audit/_defaults.yaml"
render_to "$TPL/core/log-archive/_defaults.yaml.tmpl"   "$out/core/log-archive/_defaults.yaml"
tenant=$(aget example_tenant)
region=$(aget primary_region)
render_to "$TPL/tenant/_defaults.yaml.tmpl"             "$out/$tenant/_defaults.yaml"
render_to "$TPL/tenant/region.yaml.tmpl"                "$out/$tenant/dev/$region.yaml"

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "=== plan ==="
    printf '%s\n' "${plan_lines[@]}"
    exit 0
fi

if [[ $SKIP_REMOTE -eq 1 ]]; then
    echo "scaffold written under $out — --skip-remote: not committing/pushing"
    exit 0
fi

branch="bootstrap/${ns}-init"
git -C "$REPO" checkout -B "$branch"
git -C "$REPO" add "stacks/orgs/$ns"
git -C "$REPO" commit -m "bootstrap($ns): initial scaffold"
git -C "$REPO" push -u origin "$branch"
gh pr create --title "bootstrap($ns): initial scaffold" \
    --body "Generated by \`atmos bootstrap\`. Review and merge to enable CI for this namespace." \
    --base main --head "$branch"
