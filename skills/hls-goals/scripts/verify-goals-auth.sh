#!/usr/bin/env bash
#
# Confirm HLS_GOALS_TOKEN works, and say precisely what is wrong when it doesn't.
# Never prints the token. Read-only: two GETs.

set -uo pipefail

BASE="${HLS_GOALS_BASE:-http://10.0.135.53:3000}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail() { echo; echo "FAILED: $*" >&2; exit 1; }

echo "Goals board: $BASE"

if [[ -z "${HLS_GOALS_TOKEN:-}" ]]; then
    cat >&2 <<EOF

FAILED: HLS_GOALS_TOKEN is not set.

  1. Log in to the board, click API in the top right of the navbar, create a token
     with no expiry, and copy the secret.
  2. Put it in .claude/settings.local.json under "env" — NOT .claude/settings.json,
     which is committed and would share the token with the whole team:

       { "env": { "HLS_GOALS_TOKEN": "" } }

  3. Check the file is gitignored before pasting anything into it:

       git check-ignore -v .claude/settings.local.json

  4. Paste the value yourself, in your editor. Do not paste it into chat.
  5. Save. No restart needed — env reaches a running session immediately. Re-run this script.

See $HERE/../SKILL.md for the full setup.
EOF
    exit 1
fi

echo "HLS_GOALS_TOKEN: set (value not shown)"

# Reachability, before blaming the token for a network problem.
code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 "$BASE/api/docs" 2>/dev/null)"
if [[ "$code" == "000" ]]; then
    fail "cannot reach $BASE (TCP connect failed). On the VPN? The host has previously dropped connections intermittently while still answering ICMP."
fi
echo "Reachable:       yes (unauthenticated probe returned $code)"

out="$(curl -sS -w $'\n%{http_code}' -H "Authorization: Bearer $HLS_GOALS_TOKEN" --max-time 20 "$BASE/api/auth/me" 2>/dev/null)"
status="${out##*$'\n'}"
body="${out%$'\n'*}"

case "$status" in
    200) ;;
    401)
        detail="$(printf '%s' "$body" | jq -r '.error // "unknown"' 2>/dev/null)"
        if [[ "$detail" == *"revoked"* || "$detail" == *"invalid"* ]]; then
            fail "the token was rejected as invalid or revoked ($detail). Create a new one on the board and update .claude/settings.local.json."
        fi
        fail "not authenticated ($detail). The variable is set but the API did not accept it — check for a stray quote or whitespace in settings.local.json."
        ;;
    *) fail "unexpected HTTP $status from /api/auth/me" ;;
esac

echo "Authenticated:   $(printf '%s' "$body" | jq -r '"\(.name) <\(.email)>"')"

teams="$(curl -sS -H "Authorization: Bearer $HLS_GOALS_TOKEN" --max-time 20 "$BASE/api/teams" 2>/dev/null)"
if printf '%s' "$teams" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "Teams:           $(printf '%s' "$teams" | jq -r 'length') — $(printf '%s' "$teams" | jq -r 'map("\(.name) (\(.role))") | join(", ")')"
    echo
    echo "OK. Token works. Writes will be attributed to the account above."
else
    fail "/api/teams did not return an array; the API may have changed. Report this rather than working around it."
fi
