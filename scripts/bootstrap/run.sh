#!/usr/bin/env bash
# atmos bootstrap - A (gather) → B (scaffold PR) → C (apply bootstrap: central + per-account).
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

Phases: A gather · B scaffold+PR · C apply bootstrap (central + per-account)

Flags:
  --answers FILE        Load answers from YAML (skips interactive prompts)
  --dry-run             Print plans + intended commands for every phase; execute nothing
  --print-questions     Emit answer-file schema on stdout and exit
  --skip-remote         After scaffold, do not commit/push/open PR (implies stop after B)
  --yes / -y            Non-interactive: auto-continue between phases
  --phase LETTER        Run only this phase (A|B|C)
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

# Confirm gh is authenticated. Per-repo write-access check happens after
# Phase A captures github_org/github_repo (verify_gh_repo_access).
gh auth status --hostname github.com >/dev/null 2>&1 \
    || die "gh is not authenticated. Run 'gh auth login' as a user with write access to the deployment repo, then re-run."

# Confirm the active gh account has push access to <github_org>/<github_repo>
# from the captured answers. Called at end of Phase A.
verify_gh_repo_access() {
    local org repo perm active
    org=$(aget github_org); repo=$(aget github_repo)
    [[ -n "$org" && -n "$repo" ]] || return 0
    active=$(gh auth status --hostname github.com 2>&1 | awk '/Active account: true/{getline; sub(/.*account /,""); sub(/ .*/,""); print; exit}' || true)
    if ! perm=$(gh api "repos/$org/$repo" --jq '.permissions.push' 2>/dev/null); then
        die "gh ($active) cannot read $org/$repo. Switch accounts with 'gh auth switch', then re-run."
    fi
    if [[ "$perm" != "true" ]]; then
        die "gh active account ($active) lacks push access to $org/$repo. Switch with 'gh auth switch', then re-run."
    fi
}

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
    local order="ABC"
    local from_idx="${order%%"${FROM:-A}"*}"; from_idx=${#from_idx}
    local to_idx="${order%%"${TO:-C}"*}"; to_idx=${#to_idx}
    local p_idx="${order%%"${p}"*}"; p_idx=${#p_idx}
    (( p_idx >= from_idx && p_idx <= to_idx ))
}

phase_description() {
    local ns
    case "$1" in
        A) echo "gather answers (interactive prompts or load cached .bootstrap-answers.yaml)" ;;
        B)
            ns="$(aget namespace 2>/dev/null || true)"
            if [[ -n "$ns" && -f "$REPO/stacks/orgs/$ns/_defaults.yaml" ]]; then
                echo "skip (scaffold already present at stacks/orgs/$ns)"
            else
                echo "render stack scaffold under stacks/orgs/<ns>/, commit on bootstrap/<ns>-init, open PR"
            fi
            ;;
        C) echo "apply central components, stamp AtmosDeploymentRole + tfstate-backend into every CT-core account, and publish GHA repo vars" ;;
        *) echo "" ;;
    esac
}

confirm_continue() {
    local phase="$1" desc
    desc=$(phase_description "$phase")
    [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0
    has_tty || return 0
    local ans prompt
    if [[ -n "$desc" ]]; then
        prompt="Proceed to Phase $phase - $desc?"
    else
        prompt="Proceed to Phase $phase?"
    fi
    if use_gum; then
        gum confirm "$prompt" || return 1
    else
        printf "%s [Y/n] " "$prompt" >&2
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

# Cache path for captured answers. Auto-loaded on re-run when the user
# doesn't pass --answers explicitly. Gitignored.
DEFAULT_ANSWERS_CACHE="$REPO/.bootstrap-answers.yaml"

persist_answers_cache() {
    local path="$1"
    {
        echo "# Auto-generated by atmos bootstrap. Delete to re-prompt on next run."
        echo "answers:"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            local val; val=$(aget "$key")
            # YAML-safe double-quoted scalar (escape \ as \\ and " as \").
            local escaped="${val//\\/\\\\}"
            escaped="${escaped//\"/\\\"}"
            printf '  %s: "%s"\n' "$key" "$escaped"
        done < <(yq -r '.questions[].key' "$QS")
    } > "$path"
    echo "phase A: cached answers to ${path#$REPO/} (delete to re-prompt next run)" >&2
}

# ---------- Phase A: gather ----------
phase_a() {
    # Auto-load cached answers when the caller didn't pass --answers.
    if [[ -z "$ANSWERS_FILE" && -r "$DEFAULT_ANSWERS_CACHE" ]]; then
        ANSWERS_FILE="$DEFAULT_ANSWERS_CACHE"
        echo "phase A: loading cached answers from ${ANSWERS_FILE#$REPO/}" >&2
    fi
    if [[ -n "$ANSWERS_FILE" ]]; then
        [[ -r "$ANSWERS_FILE" ]] || die "answers file not readable: $ANSWERS_FILE"
        while IFS=$'\t' read -r k v; do
            [[ -z "$k" ]] && continue
            validate_answer "$k" "$v"
            aput "$k" "$v"
        done < <(yq -o=tsv '.answers | to_entries | map([.key, .value]) | .[]' "$ANSWERS_FILE")
    else
        has_tty || die "no TTY for interactive prompts - use --answers FILE"
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
                atmos_external_id) default="$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)" ;;
            esac
            while :; do
                val=$(prompt_one "$key" "$msg" "$default" "$choices")
                if [[ -n "$regex" && ! "$val" =~ $regex ]]; then
                    echo "invalid - must match $regex" >&2; continue
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

    # Auto-fill atmos_external_id when missing (cached answers from before the
    # field was introduced won't have it; new prompts default to uuidgen).
    if [[ -z "$(aget atmos_external_id)" ]]; then
        aput atmos_external_id "$(uuidgen | tr '[:upper:]' '[:lower:]')"
    fi

    # Persist captured answers so subsequent runs skip prompts. Done before
    # adding derived values so the cache only holds canonical user answers.
    persist_answers_cache "$DEFAULT_ANSWERS_CACHE"

    # Derived values.
    local topology_val; topology_val=$(aget topology); [[ -z "$topology_val" ]] && topology_val="separate"
    aput separate_aft_mgmt_account "$([[ "$topology_val" == "separate" ]] && echo true || echo false)"
    aput example_tenant "plat"
    aput example_tenant_title "Plat"

    # Now that github_org / github_repo are known, confirm the active gh
    # account can push to the deployment repo. Phases B/C/D all need write
    # access (PR open, repo var set, workflow dispatch).
    verify_gh_repo_access
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
            echo "phase B: scaffold already present at stacks/orgs/$ns - skipping" >&2
            return 0
        fi
        local choice
        choice=$(prompt_one rescaffold "Continue / rescaffold / abort" "continue" "continue rescaffold abort")
        case "$choice" in
            abort) exit 0 ;;
            continue) echo "phase B: keeping existing scaffold" >&2; return 0 ;;
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
    # Core-account stack files are named gbl.yaml (not _defaults.yaml) so
    # they are picked up by atmos stack discovery - _defaults.yaml is in
    # excluded_paths in atmos.yaml.
    render_to "$TPL/core/ct-mgmt/gbl.yaml.tmpl"             "$out/core/ct-mgmt/gbl.yaml"
    render_to "$TPL/core/audit/gbl.yaml.tmpl"               "$out/core/audit/gbl.yaml"
    render_to "$TPL/core/log-archive/gbl.yaml.tmpl"         "$out/core/log-archive/gbl.yaml"
    if [[ "$(aget topology)" == "separate" ]]; then
        render_to "$TPL/core/aft-mgmt/gbl.yaml.tmpl"        "$out/core/aft-mgmt/gbl.yaml"
    fi
    local tenant region
    tenant=$(aget example_tenant); region=$(aget primary_region)
    render_to "$TPL/tenant/_defaults.yaml.tmpl"             "$out/$tenant/_defaults.yaml"
    render_to "$TPL/tenant/region.yaml.tmpl"                "$out/$tenant/dev/$region.yaml"

    # Single-account topology: fold the AFT-central catalogs into ct-mgmt
    # so 'core-gbl-mgmt' becomes the central stack (no separate aft-mgmt).
    if [[ "$(aget topology)" == "single" && $DRY_RUN -eq 0 ]]; then
        local ctmgmt="$out/core/ct-mgmt/gbl.yaml"
        if [[ -f "$ctmgmt" ]] && ! grep -q 'tfstate-backend-central' "$ctmgmt"; then
            local tmp; tmp=$(mktemp)
            awk '
                /^  - catalog\/account-classes\/ct-mgmt$/ {
                    print
                    print "  # Single-account topology: ct-mgmt absorbs the AFT-central catalogs."
                    print "  - catalog/tfstate-backend-central/defaults"
                    print "  - catalog/iam-deployment-roles/central/defaults"
                    print "  - catalog/github-oidc-provider/defaults"
                    print "  - catalog/controltower-event-bridge/defaults"
                    next
                }
                { print }
            ' "$ctmgmt" > "$tmp" && mv "$tmp" "$ctmgmt"
            plan_lines+=("inject AFT-central catalogs into ct-mgmt (single-topology)")
        fi
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        { echo; echo "=== plan ==="; printf '%s\n' "${plan_lines[@]}"; } >&2
        return 0
    fi
    if [[ $SKIP_REMOTE -eq 1 ]]; then
        echo "phase B: scaffold written under $out - --skip-remote: not committing/pushing" >&2
        return 0
    fi

    local branch="bootstrap/${ns}-init" gh_org gh_repo gh_target
    gh_org=$(aget github_org); gh_repo=$(aget github_repo)
    gh_target="$gh_org/$gh_repo"
    git -C "$REPO" checkout -B "$branch"
    git -C "$REPO" add "stacks/orgs/$ns"
    git -C "$REPO" commit -m "bootstrap($ns): initial scaffold"
    git -C "$REPO" push -u origin "$branch"
    local pr_rc=0
    gh pr create --repo "$gh_target" --title "bootstrap($ns): initial scaffold" \
        --body "Generated by \`atmos bootstrap\`. Review, merge, then re-run \`atmos bootstrap\` to continue (Phase C applies central components, Phase D dispatches fleet bootstrap)." \
        --base main --head "$branch" >/tmp/pr-create.out 2>&1 || pr_rc=$?
    if [[ $pr_rc -ne 0 ]]; then
        if grep -q "already exists" /tmp/pr-create.out; then
            local pr_url
            pr_url=$(gh pr list --repo "$gh_target" --state open --head "$branch" --json url -q '.[0].url')
            echo "PR already exists: $pr_url"
        elif grep -qE "Head sha can't be blank|No commits between" /tmp/pr-create.out; then
            # gh pr create uses GraphQL, which fails on freshly-pushed branches in
            # newly-created repos until indexing catches up. The REST endpoint works.
            echo "gh pr create (GraphQL) tripped on a fresh-repo edge case; retrying via REST..."
            local pr_url
            pr_url=$(gh api "repos/$gh_target/pulls" -X POST \
                -f title="bootstrap($ns): initial scaffold" \
                -f head="$branch" -f base=main \
                -f body="Generated by \`atmos bootstrap\`. Review, merge, then re-run \`atmos bootstrap\` to continue (Phase C applies central components, Phase D dispatches fleet bootstrap)." \
                --jq '.html_url') \
                || die "REST fallback also failed for gh pr create: $(cat /tmp/pr-create.out)"
            echo "PR created via REST: $pr_url"
        else
            die "gh pr create failed: $(cat /tmp/pr-create.out)"
        fi
    else
        cat /tmp/pr-create.out
    fi
    echo
    echo "PHASE B complete. Merge the PR, then re-run 'atmos bootstrap' to continue." >&2
    exit 0
}

# Run a callback under STS-assumed credentials.
# Args: target_role_arn callback args...
# If target_role_arn is empty, runs callback directly (no assume).
with_assumed_role() {
    local target_arn="$1"; shift
    if [[ -z "$target_arn" ]]; then
        "$@"
        return
    fi
    local creds
    creds=$(aws sts assume-role --role-arn "$target_arn" \
        --role-session-name atmos-bootstrap \
        --duration-seconds 900 \
        --query Credentials --output json 2>/dev/null) || return 2
    AWS_ACCESS_KEY_ID=$(jq -r .AccessKeyId <<<"$creds") \
    AWS_SECRET_ACCESS_KEY=$(jq -r .SecretAccessKey <<<"$creds") \
    AWS_SESSION_TOKEN=$(jq -r .SessionToken <<<"$creds") \
        "$@"
}

# Resolve which bootstrap role works in a target account, preferring OAAR
# then AWSControlTowerExecution. Echoes the working role ARN, or empty.
resolve_bootstrap_role() {
    local acct="$1" name
    if [[ $DRY_RUN -eq 1 ]]; then
        # No live STS in dry-run; assume OAAR for the printed plan.
        echo "arn:aws:iam::${acct}:role/OrganizationAccountAccessRole"
        return 0
    fi
    for name in OrganizationAccountAccessRole AWSControlTowerExecution; do
        local arn="arn:aws:iam::${acct}:role/${name}"
        if aws sts assume-role --role-arn "$arn" --role-session-name atmos-probe \
            --duration-seconds 900 --query Credentials.AccessKeyId \
            --output text >/dev/null 2>&1; then
            echo "$arn"
            return 0
        fi
    done
    return 1
}

# Apply tfstate-backend in a target account (creates per-account state bucket
# + KMS, then migrates local state to S3). Idempotent: skips the local-first
# apply when the bucket already exists.
#
# Cross-account auth: with_assumed_role exports STS-assumed creds for the
# target account so terraform's S3 backend (and AWS provider) operate
# directly as that identity. We clear TF_VAR_target_role_arn to avoid a
# double-assume in the provider's dynamic assume_role block.
stamp_account_state() {
    local stack="$1" acct="$2" target_arn="${3:-}"
    local backend_bucket tb_dir="$REPO/components/terraform/tfstate-backend"
    backend_bucket=$(atmos describe component tfstate-backend -s "$stack" --format json \
        | jq -r '.backend.bucket')
    [[ -n "$backend_bucket" && "$backend_bucket" != "null" ]] || \
        die "no backend.bucket for tfstate-backend in $stack"
    local exists=1
    if [[ $DRY_RUN -eq 0 ]]; then
        with_assumed_role "$target_arn" aws s3api head-bucket --bucket "$backend_bucket" \
            >/dev/null 2>&1 && exists=0 || exists=1
    fi
    if [[ $DRY_RUN -eq 0 && $exists -eq 0 ]]; then
        echo "  skip: tfstate-backend bucket $backend_bucket already present in $acct" >&2
    else
        echo "  apply: tfstate-backend in $acct (local backend, creates s3://$backend_bucket)" >&2
        rm -f "$tb_dir/backend.tf.json"
        TF_VAR_target_role_arn="" run with_assumed_role "$target_arn" \
            atmos terraform apply tfstate-backend -s "$stack" \
            --auto-generate-backend-file=false -- -auto-approve
    fi
    TF_VAR_target_role_arn="" run with_assumed_role "$target_arn" \
        atmos terraform init tfstate-backend -s "$stack" \
        --init-run-reconfigure=false -- -migrate-state -input=false -force-copy
}

# Run a command and retry on IAM eventual-consistency failures - the
# 'MalformedPolicyDocument: Invalid principal' error AWS returns for a few
# seconds after a referenced role is created. Captures combined stdout+stderr
# so the error class can be pattern-matched after the fact.
retry_iam_consistency() {
    local attempts=5 delay=10 i=1 rc errlog
    errlog=$(mktemp)
    while (( i <= attempts )); do
        rc=0
        ( "$@" ) >"$errlog" 2>&1 || rc=$?
        cat "$errlog"
        if (( rc == 0 )); then
            rm -f "$errlog"
            return 0
        fi
        if grep -q "MalformedPolicyDocument" "$errlog" \
            && grep -q "Invalid principal" "$errlog" \
            && (( i < attempts )); then
            echo "  IAM eventual consistency hit; sleeping ${delay}s and retrying ($i/$attempts)" >&2
            sleep "$delay"
            delay=$((delay * 2))
            i=$((i+1))
            continue
        fi
        rm -f "$errlog"
        return $rc
    done
    rm -f "$errlog"
    return 1
}

# Stamp AtmosDeploymentRole in a target account. Skips when present.
stamp_account_role() {
    local stack="$1" acct="$2" target_arn="${3:-}"
    if [[ $DRY_RUN -eq 0 ]] && \
        with_assumed_role "$target_arn" aws iam get-role --role-name AtmosDeploymentRole \
        >/dev/null 2>&1; then
        echo "  skip: AtmosDeploymentRole already present in $acct" >&2
    else
        echo "  apply: iam-deployment-roles/target in $acct (stamps AtmosDeploymentRole)" >&2
        # iam-deployment-roles/target's trust policies reference
        # AtmosCentralDeploymentRole / AtmosPlanOnlyRole which were just
        # created in the previous step - retry on IAM eventual consistency.
        TF_VAR_target_role_arn="" run retry_iam_consistency with_assumed_role "$target_arn" \
            atmos terraform apply iam-deployment-roles/target -s "$stack" -- -auto-approve
    fi
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
    local branch="bootstrap/${ns}-init" pr_state="" gh_org gh_repo gh_target
    gh_org=$(aget github_org); gh_repo=$(aget github_repo)
    gh_target="$gh_org/$gh_repo"
    if command -v gh >/dev/null 2>&1; then
        pr_state=$(gh pr list --repo "$gh_target" --head "$branch" --state all --json state --jq '.[0].state' 2>/dev/null || true)
    fi
    if [[ -n "$pr_state" && "$pr_state" != "MERGED" ]]; then
        die "phase C: scaffold PR on branch $branch is $pr_state - merge it first, then re-run"
    fi

    # Credential check. OAAR expected via current env (AWS_PROFILE or STS creds).
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! aws sts get-caller-identity >/dev/null 2>&1; then
            die "phase C: AWS credentials not usable - set AWS_PROFILE / AWS_* for the aft-mgmt account OAAR session"
        fi
        local actual expected
        actual=$(aws sts get-caller-identity --query Account --output text)
        expected=$(aget aft_mgmt_account_id)
        if [[ "$actual" != "$expected" ]]; then
            die "Phase C requires credentials for $expected (aft_mgmt), but current caller is $actual"
        fi
    fi

    # Catalog imports !env ATMOS_EXTERNAL_ID for the four CT-core role trust
    # policies; export it from the cached answer so atmos resolves it.
    export ATMOS_EXTERNAL_ID="$(aget atmos_external_id)"

    echo "phase C: applying central components to $central_stack" >&2

    # Resolve the central state bucket from the stack config - backend.bucket
    # is templated in stacks/orgs/_defaults.yaml as
    # {tenant}-{environment}-{stage}-{account_id}, so atmos returns the right
    # name for whichever topology / region this deployment uses.
    local bucket
    bucket=$(atmos describe component tfstate-backend-central -s "$central_stack" --format json \
        | jq -r '.backend.bucket')
    [[ -n "$bucket" && "$bucket" != "null" ]] || \
        die "phase C: could not resolve backend.bucket for tfstate-backend-central in $central_stack"

    # Order matters: oidc → central-roles → tfstate-backend-central. The
    # tfstate-backend-central bucket policy references the IAM roles from
    # iam-deployment-roles/central; applying it before those roles exist
    # returns MalformedPolicy 'Invalid principal'. All three apply with
    # LOCAL state on first run (bucket doesn't exist yet); after step 3
    # the bucket is in place and init -migrate-state lifts each
    # component's local state into S3.
    #
    # Idempotency: skip a component's local-apply only when its state is
    # already in S3 (i.e., a previous run successfully migrated). A partial
    # failure (e.g., bucket created but policy never applied) leaves state
    # local, not in S3, so we re-apply and terraform converges via its
    # local-state diff.

    # Returns 0 if the given component's state file already exists in the
    # central S3 bucket. Used to short-circuit the local-apply phase.
    state_in_s3() {
        local component="$1" key
        key=$(atmos describe component "$component" -s "$central_stack" --format json 2>/dev/null \
            | jq -r '.backend.key')
        [[ -n "$key" && "$key" != "null" ]] || return 1
        aws s3api head-object --bucket "$bucket" --key "$key" >/dev/null 2>&1
    }

    for comp in github-oidc-provider iam-deployment-roles/central tfstate-backend-central; do
        if [[ $DRY_RUN -eq 0 ]] && state_in_s3 "$comp"; then
            echo "  skip: $comp state already in S3" >&2
        else
            echo "  apply: $comp (local backend)" >&2
            rm -f "$REPO/components/terraform/$comp/backend.tf.json"
            run atmos terraform apply "$comp" -s "$central_stack" \
                --auto-generate-backend-file=false -- -auto-approve
        fi
    done

    # Migrate each component's local state to the S3 bucket. atmos regenerates
    # backend.tf.json with S3; --init-run-reconfigure=false avoids the
    # -reconfigure/-migrate-state mutual-exclusion conflict. No-op when state
    # is already in S3.
    for comp in github-oidc-provider iam-deployment-roles/central tfstate-backend-central; do
        run atmos terraform init "$comp" -s "$central_stack" \
            --init-run-reconfigure=false -- -migrate-state -input=false -force-copy
    done

    # 4. Per-CT-core stamping: tfstate-backend (per-account state bucket) and
    # iam-deployment-roles/target (stamps AtmosDeploymentRole). Cross-account
    # work uses STS-assumed OAAR / AWSControlTowerExecution from CT-mgmt creds.
    echo "phase C: stamping per-account state buckets + AtmosDeploymentRole" >&2
    local mgmt_id audit_id log_archive_id aft_id
    mgmt_id=$(aget management_account_id)
    audit_id=$(aget audit_account_id)
    log_archive_id=$(aget log_archive_account_id)
    aft_id=$(aget aft_mgmt_account_id)

    local audit_role log_archive_role
    audit_role=$(resolve_bootstrap_role "$audit_id") \
        || die "phase C: no working bootstrap role (OAAR/AWSControlTowerExecution) in audit account $audit_id"
    log_archive_role=$(resolve_bootstrap_role "$log_archive_id") \
        || die "phase C: no working bootstrap role in log-archive account $log_archive_id"

    if [[ "$topology" == "single" ]]; then
        # Single-topology: ct-mgmt IS the central account. State already in
        # tfstate-backend-central; just stamp AtmosDeploymentRole locally.
        stamp_account_role "core-gbl-mgmt" "$mgmt_id" ""
        stamp_account_state "core-gbl-audit" "$audit_id" "$audit_role"
        stamp_account_role  "core-gbl-audit" "$audit_id" "$audit_role"
        stamp_account_state "core-gbl-log-archive" "$log_archive_id" "$log_archive_role"
        stamp_account_role  "core-gbl-log-archive" "$log_archive_id" "$log_archive_role"
    else
        # Separate-topology: aft-mgmt is central (state already done above);
        # stamp role locally there. ct-mgmt + audit + log-archive are full stamps.
        stamp_account_role "aft-gbl-mgmt" "$aft_id" ""
        local mgmt_role
        mgmt_role=$(resolve_bootstrap_role "$mgmt_id") \
            || die "phase C: no working bootstrap role in ct-mgmt account $mgmt_id"
        stamp_account_state "core-gbl-mgmt" "$mgmt_id" "$mgmt_role"
        stamp_account_role  "core-gbl-mgmt" "$mgmt_id" "$mgmt_role"
        stamp_account_state "core-gbl-audit" "$audit_id" "$audit_role"
        stamp_account_role  "core-gbl-audit" "$audit_id" "$audit_role"
        stamp_account_state "core-gbl-log-archive" "$log_archive_id" "$log_archive_role"
        stamp_account_role  "core-gbl-log-archive" "$log_archive_id" "$log_archive_role"
    fi

    # 5. Publish GHA repo variables that downstream workflows depend on.
    # Values are deterministic from Phase A answers and the role names the
    # central component creates - safe to (re)set on every Phase C run.
    local gh_repo_l region auth_mode central_arn plan_only_arn
    region=$(aget primary_region); auth_mode=$(aget aws_auth_mode)
    central_arn="arn:aws:iam::${aft_id}:role/AtmosCentralDeploymentRole"
    plan_only_arn="arn:aws:iam::${aft_id}:role/AtmosPlanOnlyRole"
    echo "phase C: publishing GHA repo vars + secret on $gh_target" >&2
    run gh variable set ATMOS_CENTRAL_ROLE_ARN  --repo "$gh_target" --body "$central_arn"
    run gh variable set ATMOS_PLAN_ONLY_ROLE_ARN --repo "$gh_target" --body "$plan_only_arn"
    run gh variable set AWS_REGION              --repo "$gh_target" --body "$region"
    run gh variable set AFT_AUTH_MODE           --repo "$gh_target" --body "$auth_mode"
    # ATMOS_EXTERNAL_ID is a repo secret (configure-aws reads it via secrets
    # context, not vars). Already in the cached answers; publish it here so
    # GHA workflows can read it.
    run gh secret   set ATMOS_EXTERNAL_ID       --repo "$gh_target" --body "$ATMOS_EXTERNAL_ID"
}

# ---------- driver ----------
# Phase A (gather) has no side effects and is a prerequisite for B/C.
# Always run it; --phase / --from / --to only gate the action phases.
phase_a
phase_enabled B && { confirm_continue B && phase_b || die "aborted before phase B"; }
phase_enabled C && { confirm_continue C && phase_c || die "aborted before phase C"; }

echo "bootstrap: done"
