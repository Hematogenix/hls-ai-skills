#!/usr/bin/env bash
#
# GitHub Projects (v2) + issues workflow, wrapped so there is one place to fix the mechanics.
#
# Everything the project board needs is a node ID, never a human-readable name, so the id lookups live in
# resolve_* below and are cached for the life of one invocation.

set -euo pipefail

BACKLOG_STATUS="${HLS_BOARD_BACKLOG:-Backlog}"
STATUS_FIELD="${HLS_BOARD_STATUS_FIELD:-Status}"
ITEM_LIMIT="${HLS_BOARD_LIMIT:-500}"

OWNER="${HLS_BOARD_OWNER:-}"
NUMBER="${HLS_BOARD_NUMBER:-}"
ASSUME_YES=no

CACHE=""
trap 'rm -rf "$CACHE"' EXIT

die() { echo "error: $*" >&2; exit 1; }
note() { echo "$*" >&2; }

confirm_write() {
    [[ "$ASSUME_YES" == yes ]] || die "$1 writes to a board other people read. Confirm with the person, then re-run with --yes."
}

# Strips the config flags out of any subcommand's arguments, leaving the rest in REST.
parse_common() {
    REST=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --owner)   OWNER="$2"; shift 2 ;;
            --project) NUMBER="$2"; shift 2 ;;
            --yes)     ASSUME_YES=yes; shift ;;
            *)         REST+=("$1"); shift ;;
        esac
    done
}

require_gh() {
    command -v gh >/dev/null || die "gh is not installed."
    command -v jq >/dev/null || die "jq is not installed."
    gh auth status >/dev/null 2>&1 || die "gh is not authenticated. Run: gh auth login"
}

# `project` scope is not granted by default, and read:project is not enough to move a card.
require_project_scope() {
    local scopes
    scopes="$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p' | tr -d "'")"
    case "${scopes//read:project/}" in
        *project*) : ;;
        *) die "the gh token has no project scope (has: ${scopes:-unknown}). Run: gh auth refresh -s project
       read:project only lists a board; moving a card needs the full project scope." ;;
    esac
}

# Owner defaults to the current repo's owner, which is right whenever the board belongs to the same org.
resolve_target() {
    [[ -n "$OWNER" ]] || OWNER="$(gh repo view --json owner -q .owner.login 2>/dev/null || true)"
    [[ -n "$OWNER" ]] || die "no board owner. Pass --owner, set HLS_BOARD_OWNER, or run inside the repo."
    [[ -n "$NUMBER" ]] || die "no project number. Pass --project, or set HLS_BOARD_NUMBER.
       It is the number in the board URL: github.com/orgs/$OWNER/projects/<number>
       Run scripts/verify-board-auth.sh to see the boards you can reach."
    [[ "$NUMBER" =~ ^[0-9]+$ ]] || die "--project takes the number from the board URL, got '$NUMBER'."
}

cache_dir() {
    [[ -n "$CACHE" ]] || CACHE="$(mktemp -d)"
    printf '%s' "$CACHE"
}

project_id() {
    local f; f="$(cache_dir)/project.json"
    [[ -s "$f" ]] || gh project view "$NUMBER" --owner "$OWNER" --format json >"$f" \
        || die "cannot read project $NUMBER for owner $OWNER."
    jq -r '.id' "$f"
}

fields_json() {
    local f; f="$(cache_dir)/fields.json"
    [[ -s "$f" ]] || gh project field-list "$NUMBER" --owner "$OWNER" --format json --limit 100 >"$f" \
        || die "cannot list fields on project $NUMBER."
    cat "$f"
}

status_field_id() {
    fields_json | jq -r --arg n "$STATUS_FIELD" '.fields[] | select(.name == $n) | .id' | head -1
}

# Option names are matched case-insensitively because boards vary between "Todo", "To do" and "To Do".
status_option_id() {
    fields_json | jq -r --arg n "$STATUS_FIELD" --arg o "$1" '
        .fields[] | select(.name == $n) | .options[]
        | select((.name | ascii_downcase) == ($o | ascii_downcase)) | .id' | head -1
}

status_option_names() {
    fields_json | jq -r --arg n "$STATUS_FIELD" '.fields[] | select(.name == $n) | .options[].name'
}

items_json() {
    local f; f="$(cache_dir)/items.json"
    [[ -s "$f" ]] || gh project item-list "$NUMBER" --owner "$OWNER" --format json --limit "$ITEM_LIMIT" >"$f" \
        || die "cannot list items on project $NUMBER."
    cat "$f"
}

# There is no lookup-by-issue-number API, so this is a client-side scan of the fetched page.
item_id_for_issue() {
    local num="$1" id
    id="$(items_json | jq -r --argjson n "$num" '
        .items[] | select(.content.type == "Issue" and .content.number == $n) | .id' | head -1)"
    [[ -n "$id" ]] || die "issue #$num is not on project $NUMBER (searched the first $ITEM_LIMIT items).
       Add it first: gh project item-add $NUMBER --owner $OWNER --url \$(gh issue view $num --json url -q .url)"
    printf '%s' "$id"
}

# Takes an issue number, not an item id: `set_status "$(item_id_for_issue n)"` would swallow that lookup's
# failure, because a die inside a command substitution does not stop the caller.
set_status_for_issue() {
    local item_id
    item_id="$(item_id_for_issue "$1")" || exit 1
    set_status "$item_id" "$2"
}

set_status() {
    local item_id="$1" status="$2" fid oid
    [[ -n "$item_id" ]] || die "no project item id — refusing to edit."
    fid="$(status_field_id)"
    [[ -n "$fid" ]] || die "project $NUMBER has no '$STATUS_FIELD' field. Set HLS_BOARD_STATUS_FIELD if it is named differently."
    oid="$(status_option_id "$status")"
    [[ -n "$oid" ]] || die "'$status' is not an option on '$STATUS_FIELD'. Options are:
$(status_option_names | sed 's/^/         /')"
    gh project item-edit --id "$item_id" --project-id "$(project_id)" \
        --field-id "$fid" --single-select-option-id "$oid" >/dev/null
}

# One row per item: number, status, assignees, title. Custom fields come back keyed by lowercased field name,
# so `status` is read defensively in case the board renamed it.
render_items() {
    jq -r --arg sf "$STATUS_FIELD" '
        .items[] | select(.content.type == "Issue")
        | [ "#\(.content.number)",
            (.status // .[$sf] // .[$sf | ascii_downcase] // "-"),
            ((.assignees // .content.assignees // []) | join(",") | if . == "" then "-" else . end),
            .content.title ]
        | @tsv' | column -t -s $'\t'
}

item_status() {
    jq -r --arg sf "$STATUS_FIELD" --argjson n "$1" '
        .items[] | select(.content.number == $n)
        | (.status // .[$sf] // .[$sf | ascii_downcase] // "-")'
}

# --- subcommands ------------------------------------------------------------

cmd_board() {
    local want=""
    [[ ${#REST[@]} -gt 0 ]] && want="${REST[0]}"
    if [[ -n "$want" ]]; then
        items_json | jq --arg s "$want" '{items: [.items[] | select((.status // "") | ascii_downcase == ($s | ascii_downcase))]}' | render_items
    else
        items_json | render_items
    fi
}

cmd_mine() {
    local me; me="$(gh api user -q .login)"
    items_json | jq --arg me "$me" '{items: [.items[] | select(((.assignees // .content.assignees) // []) | index($me))]}' | render_items
}

cmd_issue() {
    local n="${REST[0]:-}"; [[ -n "$n" ]] || die "issue <number>"
    gh issue view "$n" --json number,title,state,labels,assignees,url,body \
        --template '#{{.number}} {{.title}} [{{.state}}]
{{.url}}
labels: {{range .labels}}{{.name}} {{end}}
assignees: {{range .assignees}}{{.login}} {{end}}

{{.body}}
'
    echo "--- board ---"
    echo "status: $(items_json | item_status "$n")"
    echo "--- linked branches ---"
    gh issue develop --list "$n" || true
}

# The only write that does not need --yes: it creates a branch and moves a card the person just asked to work.
cmd_work() {
    local n="${REST[0]:-}"; [[ -n "$n" ]] || die "work <number>"
    git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository."
    git symbolic-ref -q HEAD >/dev/null || die "HEAD is detached. Check out a branch first — gh issue develop cannot branch from a detached HEAD."

    gh issue develop "$n" --checkout
    set_status_for_issue "$n" "${HLS_BOARD_ACTIVE:-In Progress}"

    echo
    echo "on branch: $(git rev-parse --abbrev-ref HEAD)"
    echo "issue #$n moved to ${HLS_BOARD_ACTIVE:-In Progress}"
}

cmd_new() {
    local title="" body_file="" labels=() assign=no i=0
    while [[ $i -lt ${#REST[@]} ]]; do
        case "${REST[$i]}" in
            --title)     title="${REST[$((i+1))]}"; i=$((i+2)) ;;
            --body-file) body_file="${REST[$((i+1))]}"; i=$((i+2)) ;;
            --label)     labels+=(--label "${REST[$((i+1))]}"); i=$((i+2)) ;;
            --assign-me) assign=yes; i=$((i+1)) ;;
            *) die "unknown flag for new: ${REST[$i]}" ;;
        esac
    done
    [[ -n "$title" ]] || die "new --title \"...\" --body-file <file> --yes"
    [[ -n "$body_file" && -f "$body_file" ]] || die "new needs --body-file pointing at a real file. Write the body to a file rather than inlining it, so quoting cannot mangle it."
    confirm_write "creating an issue"

    local extra=()
    [[ "$assign" == yes ]] && extra+=(--assignee @me)

    local url
    url="$(gh issue create --title "$title" --body-file "$body_file" "${labels[@]+"${labels[@]}"}" "${extra[@]+"${extra[@]}"}")"
    echo "$url"

    gh project item-add "$NUMBER" --owner "$OWNER" --url "$url" >/dev/null
    rm -f "$(cache_dir)/items.json"   # the cached listing predates the item we just added
    local n; n="${url##*/}"
    set_status_for_issue "$n" "${HLS_BOARD_NEW:-Todo}"
    echo "added to project $NUMBER as ${HLS_BOARD_NEW:-Todo}"
}

cmd_defer() {
    local n="" reason="" i=0
    while [[ $i -lt ${#REST[@]} ]]; do
        case "${REST[$i]}" in
            --reason) reason="${REST[$((i+1))]}"; i=$((i+2)) ;;
            *)        n="${REST[$i]}"; i=$((i+1)) ;;
        esac
    done
    [[ -n "$n" ]] || die "defer <number> --reason \"...\" --yes"
    [[ -n "$reason" ]] || die "defer needs --reason: the board shows what moved, only the comment says why."
    confirm_write "deferring an issue"

    set_status_for_issue "$n" "$BACKLOG_STATUS"
    gh issue comment "$n" --body "Deferred to $BACKLOG_STATUS: $reason" >/dev/null
    gh issue edit "$n" --remove-assignee @me >/dev/null 2>&1 || true
    echo "#$n moved to $BACKLOG_STATUS"
}

cmd_comment() {
    local n="${REST[0]:-}" text="${REST[1]:-}"
    [[ -n "$n" && -n "$text" ]] || die "comment <number> \"text\" --yes"
    confirm_write "commenting on an issue"
    gh issue comment "$n" --body "$text"
}

cmd_status() {
    local n="${REST[0]:-}" s="${REST[1]:-}"
    [[ -n "$n" && -n "$s" ]] || die "status <number> \"<option>\" --yes
options: $(status_option_names | paste -sd', ')"
    confirm_write "moving a card"
    set_status_for_issue "$n" "$s"
    echo "#$n -> $s"
}

cmd_pr() {
    local target=()
    [[ -n "${REST[0]:-}" ]] && target=("${REST[0]}")

    local json
    json="$(gh pr view "${target[@]+"${target[@]}"}" --json number,title,isDraft,state,mergeable,reviewDecision,statusCheckRollup,url)" \
        || die "no PR found. Pass a number, or check out the branch whose PR you mean."

    printf '%s' "$json" | jq -r '
        "#\(.number) \(.title)\n\(.url)",
        "draft: \(.isDraft)   state: \(.state)   mergeable: \(.mergeable)   review: \(.reviewDecision // "none")",
        "checks: " + ((.statusCheckRollup // []) | (
            "\(map(select(.conclusion == "SUCCESS")) | length) pass, " +
            "\(map(select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED")) | length) fail, " +
            "\(map(select(.status != "COMPLETED")) | length) pending")),
        ((.statusCheckRollup // [])[]
         | select(.conclusion == "FAILURE" or .conclusion == "TIMED_OUT" or .conclusion == "CANCELLED")
         | "  FAILED  \(.name)  \(.detailsUrl // "")")'

    closing_issues "$(printf '%s' "$json" | jq -r .url)"
}

# `gh pr view --json closingIssuesReferences` only exists in newer gh, so ask GraphQL directly. This is the
# thing people miss: a linked branch does not close an issue, only a closing keyword in the body does.
closing_issues() {
    # Owner, repo and number all come from the PR's own URL, so this stays right for a PR in another repo.
    local url="$1" path owner name num raw closes
    path="${url#*github.com/}"
    owner="${path%%/*}"; path="${path#*/}"
    name="${path%%/*}"; num="${url##*/}"

    raw="$(gh api graphql -F owner="$owner" -F name="$name" -F number="$num" -f query='
        query($owner:String!,$name:String!,$number:Int!){
          repository(owner:$owner,name:$name){
            pullRequest(number:$number){
              closingIssuesReferences(first:20){ nodes { number } } } } }' \
        -q '.data.repository.pullRequest.closingIssuesReferences.nodes[].number' 2>/dev/null || true)"

    # On a GraphQL error gh prints the whole error document to stdout, so keep only bare numbers.
    closes="$(grep -oE '^[0-9]+$' <<<"$raw" | sed 's/^/#/' | paste -sd' ' || true)"

    if [[ -z "$closes" ]]; then
        echo 'closes: NOTHING — no "Closes #n" in the body, so merging will not close an issue'
    else
        echo "closes: $closes"
    fi
}

cmd_pr_create() {
    confirm_write "opening a pull request"
    git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository."

    local branch; branch="$(git rev-parse --abbrev-ref HEAD)"
    [[ "$branch" != HEAD ]] || die "detached HEAD."

    # A linked branch does not close its issue on merge; only "Closes #n" in the body does.
    local n; n="$(grep -oE '^[0-9]+' <<<"$branch" || true)"
    [[ -n "$n" ]] || n="$(grep -oE '(^|[-/_])([0-9]+)([-_]|$)' <<<"$branch" | grep -oE '[0-9]+' | head -1 || true)"
    [[ -n "$n" ]] || die "cannot tell which issue '$branch' belongs to. Create the PR by hand with 'Closes #<n>' in the body."

    local title; title="$(gh issue view "$n" --json title -q .title)"
    local body; body="$(mktemp)"
    printf 'Closes #%s\n' "$n" >"$body"

    gh pr create --draft --title "$title" --body-file "$body"
    rm -f "$body"
    cmd_pr
}

usage() {
    cat <<'EOF'
usage: board.sh <command> [args] [--owner <o>] [--project <n>] [--yes]

reading (safe)
  board [status]                 every issue on the board, optionally one status only
  mine                           board items assigned to me
  issue <n>                      body, labels, board status, linked branches
  pr [<n>]                       checks, review, mergeability, and what the PR closes

writing (--yes required, except work)
  work <n>                       gh issue develop --checkout, then move the card to In Progress
  new --title "..." --body-file <f> [--label L] [--assign-me] --yes
  defer <n> --reason "..." --yes move to Backlog, comment why, unassign
  status <n> "<option>" --yes    move a card to any status
  comment <n> "text" --yes       short note on the issue
  pr-create --yes                draft PR for the current branch with "Closes #n"

env: HLS_BOARD_OWNER, HLS_BOARD_NUMBER, HLS_BOARD_BACKLOG (default Backlog),
     HLS_BOARD_ACTIVE (In Progress), HLS_BOARD_NEW (Todo), HLS_BOARD_STATUS_FIELD (Status)
EOF
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        help|-h|--help) usage; return 0 ;;
    esac

    require_gh
    parse_common "$@"

    case "$cmd" in
        pr)        cmd_pr ;;
        pr-create) cmd_pr_create ;;
        comment)   cmd_comment ;;
        *)
            require_project_scope
            resolve_target
            case "$cmd" in
                board)  cmd_board ;;
                mine)   cmd_mine ;;
                issue)  cmd_issue ;;
                work)   cmd_work ;;
                new)    cmd_new ;;
                defer)  cmd_defer ;;
                status) cmd_status ;;
                *) die "unknown command '$cmd'. Run board.sh help." ;;
            esac
            ;;
    esac
}

main "$@"
