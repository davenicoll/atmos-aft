#!/usr/bin/env bash
# atmos bootstrap — A (gather) → B (scaffold PR) → C (apply central) → D (dispatch fleet).
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
ASSUME_YES=0
FORCE_RESCAFFOLD=0
FROM=""
TO=""
ONLY=""

usage() {
    cat <<EOF
Usage: atmos bootstrap [flags]

Phases: A gather · B scaffold+PR · C apply central components · D dispatch fleet bootstrap

Flags:
  --answers FILE        Load answers from YAML (skips interactive prompts)
  --dry-run             Print plans + intended commands for every phase; execute nothing
  --print-questions     Emit answer-file schema on stdout and exit
  --skip-remote         After scaffold, do not commit/push/open PR (implies stop after B)
  --yes / -y            Non-interactive: auto-continue between phases
  --phase LETTER        Run only this phase (A|B|C|D)
  --from LETTER         Start at this phase
  --to LETTER           Stop after this phase
  --force-rescaffold    Bypass uncommitted-changes check when rescaffolding
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --answers) ANSWERS_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --print-questions) PRINT_QUESTIONS=1; shift ;;
        --skip-remote) SKIP_REMOTE=1; shift ;;
        --yes|-y|--non-interactive) ASSUME_YES=1; shift ;;
        --phase) ONLY="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --to) TO="$2"; shift 2 ;;
        --force-rescaffold) FORCE_RESCAFFOLD=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ $PRINT_QUESTIONS -eq 1 ]]; then cat "$QS"; exit 0; fi

die() { echo "bootstrap: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# Upfront dependency checks so users fail fast, not 13 questions deep.
need yq
need jq
need aws
need atmos
need gh
need git
need terraform

# Validate an answer (key, value) against the regex declared in questions.yaml.
# No-op if the question has no `validate` field.
validate_answer() {
    local key="$1" value="$2" regex
    regex=$(yq -r ".questions[] | select(.key==\"$key\") | .validate // \"\"" "$QS")
    if [[ -n "$regex" && "$regex" != "null" && ! "$value" =~ $regex ]]; then
        die "Answer for '$key' ('$value') fails regex: $regex"
    fi
}

has_tty() { [[ -t 0 ]]; }
use_gum() { has_tty && command -v gum >/dev/null 2>&1; }

# Dry-run and non-dry-run command runner. In dry-run, print then return 0.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "DRY: $*"
    else
        "$@"
    fi
}

phase_enabled() {
    local p="$1"
    if [[ -n "$ONLY" ]]; then [[ "$ONLY" == "$p" ]] && return 0 || return 1; fi
    local order="ABCD"
    local from_idx="${order%%"${FROM:-A}"*}"; from_idx=${#from_idx}
    local to_idx="${order%%"${TO:-D}"*}"; to_idx=${#to_idx}
    local p_idx="${order%%"${p}"*}"; p_idx=${#p_idx}
    (( p_idx >= from_idx && p_idx <= to_idx ))
}

confirm_continue() {
    local phase="$1"
    [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
    has_tty || return 0
    local ans
    if use_gum; then
        gum confirm "Proceed to Phase $phase?" || return 1
    else
        printf "Proceed to Phase %s? [Y/n] " "$phase" >&2
        read -r ans
        [[ -z "$ans" || "$ans" =~ ^[Yy] ]] || return 1
    fi
}

prompt_one() {
    local key="$1" msg="$2" default="${3:-}" choices="${4:-}"
    if [[ -n "$choices" ]]; then
        if use_gum; then
            local -a _choice_arr
            read -ra _choice_arr <<<"$choices"
            gum choose --header "$msg" "${_choice_arr[@]}"
        else echo "$msg (options: $choices)" >&2; read -r v; printf '%s' "$v"; fi
    else
        if use_gum; then gum input --header "$msg" --value "$default"
        else
            local suffix=""; [[ -n "$default" ]] && suffix=" [$default]"
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

# ---------- shared answer buffer ----------
ANSWERS_BUF=""
aput() { ANSWERS_BUF="${ANSWERS_BUF}${1}=${2}"$'\n'; }
aget() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' <<<"$ANSWERS_BUF"; }

# ---------- Phase A: gather ----------
phase_a() {
    if [[ -n "$ANSWERS_FILE" ]]; then
        [[ -r "$ANSWERS_FILE" ]] || die "answers file not readable: $ANSWERS_FILE"
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" ]] && continue
            validate_answer "$k" "$v"
            aput "$k" "$v"
        done < <(yq -o=tsv '.answers | to_entries | map([.key, .value]) | .[]' "$ANSWERS_FILE")
    else
        has_tty || die "no TTY for interactive prompts — use --answers FILE"
        local gh_default gh_org gh_repo lz_default count i key msg choices regex default val
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
                    echo "invalid — must match $regex" >&2; continue
                fi
                [[ -n "$choices" ]] && { [[ " $choices " == *" $val "* ]] || { echo "invalid choice" >&2; continue; }; }
                break
            done
            aput "$key" "$val"
        done
    fi
    # Cross-field validation: topology=single requires aft_mgmt==management.
    if [[ "$(aget topology)" == "single" ]]; then
        local mgmt aft
        mgmt=$(aget management_account_id)
        aft=$(aget aft_mgmt_account_id)
        if [[ "$mgmt" != "$aft" ]]; then
            die "topology=single requires aft_mgmt_account_id == management_account_id (got $aft != $mgmt)"
        fi
    fi

    # Derived values.
    local topology_val; topology_val=$(aget topology); [[ -z "$topology_val" ]] && topology_val="separate"
    aput separate_aft_mgmt_account "$([[ "$topology_val" == "separate" ]] && echo true || echo false)"
    aput example_tenant "plat"
    aput example_tenant_title "Plat"
}

render_tpl() { ANSWERS="$ANSWERS_BUF" "$RENDER" <"$1"; }

# ---------- Phase B: scaffold + PR ----------
phase_b() {
    local ns out plan_lines
    ns="$(aget namespace)"; [[ -n "$ns" ]] || die "namespace is required"
    out="$REPO/stacks/orgs/$ns"
    plan_lines=()

    if [[ -f "$out/_defaults.yaml" ]]; then
        if [[ $ASSUME_YES -eq 1 || -n "$ANSWERS_FILE" || $DRY_RUN -eq 1 ]]; then
            echo "phase B: scaffold already present at stacks/orgs/$ns — skipping"
            return 0
        fi
        local choice
        choice=$(prompt_one rescaffold "Continue / rescaffold / abort" "continue" "continue rescaffold abort")
        case "$choice" in
            abort) exit 0 ;;
            continue) echo "phase B: keeping existing scaffold"; return 0 ;;
            rescaffold)
                if [[ $FORCE_RESCAFFOLD -eq 0 ]] && [[ -d "$out" ]] \
                    && [[ -n "$(git -C "$REPO" status --porcelain "$out" 2>/dev/null)" ]]; then
                    die "Scaffold directory '$out' has uncommitted changes. Commit or stash first, or pass --force-rescaffold."
                fi
                rm -rf "$out"
                ;;
        esac
    fi

    render_to() {
        local src="$1" dst="$2" rel="${2#"$REPO"/}"
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
    local tenant region
    tenant=$(aget example_tenant); region=$(aget primary_region)
    render_to "$TPL/tenant/_defaults.yaml.tmpl"             "$out/$tenant/_defaults.yaml"
    render_to "$TPL/tenant/region.yaml.tmpl"                "$out/$tenant/dev/$region.yaml"

    # Remove shipped example trees: they collide on stack name (e.g. plat-use1-dev)
    # with any namespace that follows the documented tenant/stage convention.
    for ex in "$REPO/stacks/orgs/example-accounts" "$REPO/stacks/orgs/example-accounts-single"; do
        if [[ -d "$ex" ]]; then
            run rm -rf "$ex"
            plan_lines+=("remove $ex (collides with namespace stacks)")
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        echo; echo "=== plan ==="; printf '%s\n' "${plan_lines[@]}"
        return 0
    fi
    if [[ $SKIP_REMOTE -eq 1 ]]; then
        echo "phase B: scaffold written under $out — --skip-remote: not committing/pushing"
        return 0
    fi

    local branch="bootstrap/${ns}-init"
    git -C "$REPO" checkout -B "$branch"
    git -C "$REPO" add -A "stacks/orgs"
    git -C "$REPO" commit -m "bootstrap($ns): initial scaffold"
    git -C "$REPO" push -u origin "$branch"
    local pr_rc=0
    gh pr create --title "bootstrap($ns): initial scaffold" \
        --body "Generated by \`atmos bootstrap\`. Review, merge, then re-run \`atmos bootstrap\` to continue (Phase C applies central components, Phase D dispatches fleet bootstrap)." \
        --base main --head "$branch" >/tmp/pr-create.out 2>&1 || pr_rc=$?
    if [[ $pr_rc -ne 0 ]]; then
        if grep -q "already exists" /tmp/pr-create.out; then
            local pr_url
            pr_url=$(gh pr list --state open --head "$branch" --json url -q '.[0].url')
            echo "PR already exists: $pr_url"
        else
            die "gh pr create failed: $(cat /tmp/pr-create.out)"
        fi
    else
        cat /tmp/pr-create.out
    fi
    echo
    echo "PHASE B complete. Merge the PR, then re-run 'atmos bootstrap' to continue."
    exit 0
}

# ---------- Phase C: apply central components ----------
phase_c() {
    need aws
    need atmos
    local ns topology central_stack region
    ns="$(aget namespace)"; topology=$(aget topology); region=$(aget primary_region)
    if [[ "$topology" == "single" ]]; then
        central_stack="core-gbl-mgmt"
    else
        central_stack="aft-gbl-mgmt"
    fi

    # Verify scaffold PR has merged.
    local branch="bootstrap/${ns}-init" pr_state=""
    if command -v gh >/dev/null 2>&1; then
        pr_state=$(gh pr list --head "$branch" --state all --json state --jq '.[0].state' 2>/dev/null || true)
    fi
    if [[ -n "$pr_state" && "$pr_state" != "MERGED" ]]; then
        die "phase C: scaffold PR on branch $branch is $pr_state — merge it first, then re-run"
    fi

    # Credential check. OAAR expected via current env (AWS_PROFILE or STS creds).
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            die "phase C: AWS credentials not usable — set AWS_PROFILE / AWS_* for the aft-mgmt account OAAR session"
        fi
        local actual expected
        actual=$(aws sts get-caller-identity --query Account --output text)
        expected=$(aget aft_mgmt_account_id)
        if [[ "$actual" != "$expected" ]]; then
            die "Phase C requires credentials for $expected (aft_mgmt), but current caller is $actual"
        fi
    fi

    echo "phase C: applying central components to $central_stack"

    # 1. github-oidc-provider — skip if present.
    local gh_host="token.actions.githubusercontent.com" oidc_arn="" acct_id
    acct_id=$(aget aft_mgmt_account_id)
    oidc_arn="arn:aws:iam::${acct_id}:oidc-provider/${gh_host}"
    if [[ $DRY_RUN -eq 0 ]] && aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$oidc_arn" >/dev/null 2>&1; then
        echo "  skip: github-oidc-provider already present"
    else
        run atmos terraform apply github-oidc-provider -s "$central_stack" --auto-approve
    fi

    # 2. iam-deployment-roles/central — skip if AtmosCentralDeploymentRole already exists.
    if [[ $DRY_RUN -eq 0 ]] && aws iam get-role --role-name AtmosCentralDeploymentRole >/dev/null 2>&1; then
        echo "  skip: AtmosCentralDeploymentRole already present"
    else
        run atmos terraform apply iam-deployment-roles/central -s "$central_stack" --auto-approve
    fi

    # 3. tfstate-backend-central — init-reconfigure to migrate local→S3 if needed, then apply.
    local bucket="${ns}-aft-mgmt-tfstate-${region}"
    if [[ $DRY_RUN -eq 0 ]] && aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
        echo "  skip: tfstate-backend-central bucket $bucket already present (still reconfiguring backend)"
        run atmos terraform init tfstate-backend-central -s "$central_stack" -- -reconfigure -migrate-state
    else
        run atmos terraform init tfstate-backend-central -s "$central_stack" -- -reconfigure -migrate-state
        run atmos terraform apply tfstate-backend-central -s "$central_stack" --auto-approve
    fi
}

# ---------- Phase D: dispatch fleet bootstrap ----------
phase_d() {
    need gh
    local ns acct_id region topology sep
    ns="$(aget namespace)"
    acct_id=$(aget aft_mgmt_account_id)
    region=$(aget primary_region)
    topology=$(aget topology)
    sep=$([[ "$topology" == "separate" ]] && echo true || echo false)

    # Skip if a recent successful bootstrap run exists.
    if [[ $DRY_RUN -eq 0 ]]; then
        local last
        last=$(gh run list --workflow bootstrap.yaml --limit 1 \
            --json status,conclusion,createdAt --jq '.[0] | select(.conclusion=="success")' 2>/dev/null || true)
        if [[ -n "$last" ]]; then
            local created_at epoch_now epoch_then
            created_at=$(jq -r '.createdAt' <<<"$last")
            epoch_now=$(date -u +%s)
            if [[ "$(uname -s)" == "Darwin" ]]; then
                epoch_then=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s)
            else
                epoch_then=$(date -u -d "$created_at" +%s)
            fi
            if (( epoch_now - epoch_then < 86400 )); then
                echo "phase D: bootstrap.yaml succeeded within last 24h ($created_at) — offering skip"
                if [[ $ASSUME_YES -eq 1 ]] || ! has_tty; then return 0; fi
                local c; c=$(prompt_one skip "Re-dispatch anyway?" "no" "yes no")
                [[ "$c" == "yes" ]] || return 0
            fi
        fi
    fi

    run gh workflow run bootstrap.yaml \
        -f "aft_mgmt_account_id=$acct_id" \
        -f "aft_mgmt_region=$region" \
        -f "separate_aft_mgmt_account=$sep" \
        -f "terraform_distribution=oss"

    if [[ $DRY_RUN -eq 0 ]] && has_tty && [[ $ASSUME_YES -eq 0 ]]; then
        local watch; watch=$(prompt_one watch "Watch run?" "yes" "yes no")
        if [[ "$watch" == "yes" ]]; then
            local run_id
            run_id=$(gh run list --workflow bootstrap.yaml --limit 1 --json databaseId --jq '.[0].databaseId')
            gh run watch "$run_id" || true
        fi
    fi
}

# ---------- driver ----------
# Phase A (gather) has no side effects and is a prerequisite for B/C/D.
# Always run it; --phase / --from / --to only gate the action phases.
phase_a
phase_enabled B && { confirm_continue B && phase_b || die "aborted before phase B"; }
phase_enabled C && { confirm_continue C && phase_c || die "aborted before phase C"; }
phase_enabled D && { confirm_continue D && phase_d || die "aborted before phase D"; }

echo "bootstrap: done"
