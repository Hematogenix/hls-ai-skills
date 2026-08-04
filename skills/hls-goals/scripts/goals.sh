#!/usr/bin/env bash
#
# HTTP wrapper for the HLS Goals board. All mechanics live here so there is one place to fix.
#
# The token is read from $HLS_GOALS_TOKEN and is never printed, never passed on a command line, and never
# written to disk. Do not add `curl -v` — it echoes the Authorization header into the transcript.

set -euo pipefail

BASE="${HLS_GOALS_BASE:-http://10.0.135.53:3000}"
UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

die() { echo "error: $*" >&2; exit 1; }

require_token() {
    [[ -n "${HLS_GOALS_TOKEN:-}" ]] || die "HLS_GOALS_TOKEN is not set. See the Setup section of SKILL.md — do not paste a token into chat."
}

# A malformed id makes the server return HTTP 500 with a zero-byte body, so validate before calling.
require_uuid() {
    [[ "$1" =~ $UUID_RE ]] || die "'$1' is not a UUID. The API answers 500 with an empty body for malformed ids, so this is checked client-side."
}

# Emits the body; on a non-2xx it explains the status using this API's actual conventions and exits 1.
call() {
    local method="$1" path="$2"; shift 2
    local out status body
    out="$(curl -sS -X "$method" -w $'\n%{http_code}' \
        -H "Authorization: Bearer $HLS_GOALS_TOKEN" \
        "$@" "$BASE$path")" || die "request failed: $method $path"
    status="${out##*$'\n'}"
    body="${out%$'\n'*}"

    case "$status" in
        2*) printf '%s' "$body"; return 0 ;;
        401) die "401 — $(msg "$body"). Either HLS_GOALS_TOKEN is unset/misspelled, or the token was revoked. Run scripts/verify-goals-auth.sh." ;;
        403) die "403 — $(msg "$body"). On a team route this can also mean the team does not exist: the membership check runs before the existence check." ;;
        404) die "404 — $(msg "$body")" ;;
        405) die "405 — $method is not allowed on $path (the route exists but not for this method)." ;;
        409) die "409 — $(msg "$body"). Completing a goal requires at least one artifact attached." ;;
        422) die "422 — $(msg "$body")" ;;
        500) die "500 with a $(printf '%s' "$body" | wc -c)-byte body. Usually a malformed id reaching the server; check the id is a UUID." ;;
        *)   die "HTTP $status — $(msg "$body")" ;;
    esac
}

# Errors are {"error": string}, except unknown paths which return an HTML 404.
msg() {
    local b="$1"
    if printf '%s' "$b" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$b" | jq -r '.error // .'
    elif [[ -z "$b" ]]; then
        printf 'empty body'
    else
        printf 'non-JSON body (unknown path returns HTML)'
    fi
}

usage() {
    cat <<'EOF'
usage: goals.sh <command> [args]

  me                                  who this token acts as
  teams                               teams and my role in each
  team <teamId>                       team detail with roster
  goals <teamId>                      the board: {goals, currentPeriods}
  mine <teamId>                       same shape, filtered to goals assigned to me
  goal <goalId>                       one goal with updates, artifacts, parent, children
  updates <goalId>                    human updates only (isAuto filtered out)
  retro <teamId> [scope] [gran]       scope=team|department  gran=quarter|month

  create --team <id> --timeframe <tf> --title "..." [--description "..."] [--parent <goalId>] [--no-assign]
                                      creates and self-assigns; --no-assign skips the assignment
  assign <goalId>                     assign yourself to an existing goal
  update <goalId> "text"              post a markdown progress update
  artifact <goalId> <file> ["note"]   attach proof of work (max 25 MB)
  complete <goalId> --yes             complete a goal; --yes is required on purpose

Set HLS_GOALS_BASE to override the default host.
EOF
}

main() {
    local cmd="${1:-help}"; shift || true
    case "$cmd" in
        help|-h|--help) usage; return 0 ;;
    esac
    require_token

    case "$cmd" in
        me)     call GET /api/auth/me ;;
        teams)  call GET /api/teams ;;
        team)   [[ $# -ge 1 ]] || die "team <teamId>"; require_uuid "$1"; call GET "/api/teams/$1" ;;
        goals)  [[ $# -ge 1 ]] || die "goals <teamId>"; require_uuid "$1"; call GET "/api/teams/$1/goals" ;;
        goal)   [[ $# -ge 1 ]] || die "goal <goalId>"; require_uuid "$1"; call GET "/api/goals/$1" ;;

        updates)
            [[ $# -ge 1 ]] || die "updates <goalId>"; require_uuid "$1"
            call GET "/api/goals/$1" | jq '[.updates[] | select(.isAuto == false)]'
            ;;

        # Same shape as `goals` so staleness stays computable against currentPeriods.
        mine)
            [[ $# -ge 1 ]] || die "mine <teamId>"; require_uuid "$1"
            local me
            me="$(call GET /api/auth/me | jq -r '.id')"
            call GET "/api/teams/$1/goals" \
                | jq --arg me "$me" '{currentPeriods, goals: [.goals[] | select(.assignees | any(.userId == $me))]}'
            ;;

        # Named flags rather than positional args: this writes to the live board, and on a team where you are
        # only a member neither PATCH nor archive is available to undo a mistake.
        create)
            local team="" tf="" title="" desc="" parent="" assign="yes"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --team)        team="$2"; shift 2 ;;
                    --timeframe)   tf="$2"; shift 2 ;;
                    --title)       title="$2"; shift 2 ;;
                    --description) desc="$2"; shift 2 ;;
                    --parent)      parent="$2"; shift 2 ;;
                    --no-assign)   assign="no"; shift ;;
                    *) die "unknown flag: $1" ;;
                esac
            done
            [[ -n "$team" && -n "$tf" && -n "$title" ]] \
                || die 'create --team <teamId> --timeframe <yearly|quarterly|monthly|weekly> --title "..." [--description "..."] [--parent <goalId>] [--no-assign]'
            require_uuid "$team"
            case "$tf" in yearly|quarterly|monthly|weekly) ;; *) die "timeframe must be yearly, quarterly, monthly or weekly (got '$tf')" ;; esac
            [[ -z "$parent" ]] || require_uuid "$parent"
            local created goal_id
            created="$(call POST "/api/teams/$team/goals" \
                -H 'Content-Type: application/json' \
                --data-binary "$(jq -nc --arg t "$title" --arg d "$desc" --arg p "$parent" --arg f "$tf" \
                    '{title:$t, timeframe:$f} + (if $d == "" then {} else {description:$d} end) + (if $p == "" then {} else {parentGoalId:$p} end)')")"
            goal_id="$(printf '%s' "$created" | jq -r '.id')"

            # Self-assign by default: an unassigned goal has no owner on the board. Omitting userId assigns the
            # caller, which any member may do; assigning anyone else is lead-only. Run in a subshell so a failed
            # assignment reports instead of killing the script — the goal already exists by this point.
            if [[ "$assign" == "yes" ]]; then
                if ( call POST "/api/goals/$goal_id/assignments" \
                        -H 'Content-Type: application/json' --data-binary '{}' >/dev/null ); then
                    call GET "/api/goals/$goal_id"      # re-read so the output shows the assignee
                    return 0
                fi
                echo "warning: goal $goal_id was created but self-assign failed — assign it manually" >&2
            fi
            printf '%s' "$created"
            ;;

        # Self only. Assigning anyone else is lead-only, so a userId argument would just earn most callers a 403.
        assign)
            [[ $# -ge 1 ]] || die "assign <goalId>  (assigns you; assigning others is lead-only and not supported here)"
            require_uuid "$1"
            call POST "/api/goals/$1/assignments" -H 'Content-Type: application/json' --data-binary '{}' >/dev/null
            call GET "/api/goals/$1" | jq '{id, title, assignees}'
            ;;

        retro)
            [[ $# -ge 1 ]] || die "retro <teamId> [scope] [granularity]"; require_uuid "$1"
            local t="$1"; shift
            local scope="${1:-team}" gran="${2:-quarter}"
            call GET "/api/teams/$t/retrospective?scope=$scope&granularity=$gran"
            ;;

        update)
            [[ $# -ge 2 ]] || die 'update <goalId> "text"'; require_uuid "$1"
            local g="$1"; shift
            call POST "/api/goals/$g/updates" \
                -H 'Content-Type: application/json' \
                --data-binary "$(jq -nc --arg t "$*" '{text:$t}')"
            ;;

        artifact)
            [[ $# -ge 2 ]] || die 'artifact <goalId> <file> ["note"]'; require_uuid "$1"
            local g="$1" f="$2"; shift 2
            [[ -f "$f" ]] || die "no such file: $f"
            if [[ $# -ge 1 ]]; then
                call POST "/api/goals/$g/artifacts" -F "file=@$f" -F "note=$*"
            else
                call POST "/api/goals/$g/artifacts" -F "file=@$f"
            fi
            ;;

        complete)
            [[ $# -ge 2 && "$2" == "--yes" ]] || die "complete <goalId> --yes. Only complete a goal when explicitly told to for that goal; --yes exists to stop this being the tail of an unattended workflow."
            require_uuid "$1"
            call POST "/api/goals/$1/complete"
            ;;

        *) usage; die "unknown command: $cmd" ;;
    esac
}

main "$@"
