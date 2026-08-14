#!/usr/bin/env bash
#
# First thing to run when anything about the board looks wrong. Prints what gh can actually do right now and
# ends with a verdict. Read-only.

set -uo pipefail

ok=yes
fail() { echo "  ✗ $*"; ok=no; }
pass() { echo "  ✓ $*"; }

echo "gh"
if ! command -v gh >/dev/null; then
    fail "gh is not installed."
    echo; echo "VERDICT: install the GitHub CLI first."; exit 1
fi
pass "$(gh --version | head -1)"
command -v jq >/dev/null && pass "jq present" || fail "jq is not installed (the scripts parse JSON with it)."

echo
echo "auth"
if ! gh auth status >/dev/null 2>&1; then
    fail "not authenticated. Run: gh auth login"
    echo; echo "VERDICT: log in first."; exit 1
fi
pass "logged in as $(gh api user -q .login 2>/dev/null || echo '?')"

scopes="$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p' | tr -d "'")"
echo "  scopes: ${scopes:-unknown}"
# read:project is a different scope and only allows listing, so drop it before looking for the write scope.
case "${scopes//read:project/}" in
    *project*) pass "project scope present" ;;
    *) case "$scopes" in
           *read:project*) fail "only read:project — listing works, moving a card does not. Run: gh auth refresh -s project" ;;
           *) fail "no project scope. Run: gh auth refresh -s project" ;;
       esac ;;
esac
case "$scopes" in *repo*) pass "repo scope present" ;; *) fail "no repo scope — issues and PRs need it." ;; esac

echo
echo "repo"
if repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
    pass "$repo"
else
    echo "  - not inside a GitHub repo (fine for board reads, not for work/new/pr)"
fi

owner="${HLS_BOARD_OWNER:-$(gh repo view --json owner -q .owner.login 2>/dev/null || true)}"
number="${HLS_BOARD_NUMBER:-}"

echo
echo "board"
if [[ -z "$owner" ]]; then
    fail "no owner. Set HLS_BOARD_OWNER or run inside the repo."
else
    echo "  owner: $owner"
    gh project list --owner "$owner" 2>/dev/null | sed 's/^/    /' || fail "cannot list projects for $owner (usually the missing project scope above)."
fi

if [[ -z "$number" ]]; then
    fail "HLS_BOARD_NUMBER is not set. Pick the number from the list above, or from the board URL."
else
    echo "  project: $number"
    if fields="$(gh project field-list "$number" --owner "$owner" --format json --limit 100 2>/dev/null)"; then
        field="${HLS_BOARD_STATUS_FIELD:-Status}"
        opts="$(printf '%s' "$fields" | jq -r --arg n "$field" '.fields[] | select(.name == $n) | .options[].name' | paste -sd', ')"
        if [[ -n "$opts" ]]; then
            pass "$field options: $opts"
            for want in "${HLS_BOARD_NEW:-Todo}" "${HLS_BOARD_ACTIVE:-In Progress}" "${HLS_BOARD_BACKLOG:-Backlog}"; do
                grep -qi -- "$want" <<<"$opts" || fail "no '$want' option — set the matching HLS_BOARD_* variable to a name this board uses."
            done
        else
            fail "no '$field' field on project $number. Set HLS_BOARD_STATUS_FIELD."
        fi
    else
        fail "cannot read project $number for $owner."
    fi
fi

echo
[[ "$ok" == yes ]] && echo "VERDICT: ready." || echo "VERDICT: fix the ✗ lines above."
[[ "$ok" == yes ]]
