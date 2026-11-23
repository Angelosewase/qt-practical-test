#!/usr/bin/env bash
# End-to-end functional checks against one deployment. Read-only except for the test data it creates.
# Usage: scripts/verify.sh http://host[:port]      (or BASE_URL=... scripts/verify.sh)
# Exit status is 0 only if every check passes.
set -uo pipefail

BASE="${1:-${BASE_URL:-http://localhost}}"
BASE="${BASE%/}"
API="$BASE/api"
ORIGIN="$BASE"
BROWSER_UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
RUN="$(date +%s)"
PASS=0
FAIL=0

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# check NAME OK(0|1) DETAIL
check() {
  if [[ "$2" -eq 0 ]]; then
    PASS=$((PASS + 1))
    echo "$(ts) PASS $1 $3"
  else
    FAIL=$((FAIL + 1))
    echo "$(ts) FAIL $1 $3"
  fi
}

# req METHOD PATH [JSON_BODY] [TOKEN]  -> sets CODE (HTTP status) and BODY (response text)
req() {
  local method="$1" path="$2" data="${3-}" token="${4-}" body_file
  body_file="$(mktemp)"
  local -a args=(-s -m 20 -o "$body_file" -w '%{http_code}' -X "$method" "$API$path")
  args+=(-A "$BROWSER_UA" -H 'Accept: application/json, text/plain, */*')
  [[ -n "$token" ]] && args+=(-H "Authorization: Bearer $token")
  # A browser sends Origin on every non-GET request made by the page. The API's CORS check depends on it (D-CORS-1).
  if [[ "$method" != GET ]]; then
    args+=(-H "Origin: $ORIGIN" -H "Referer: $ORIGIN/")
  fi
  [[ -n "$data" ]] && args+=(-H 'Content-Type: application/json' --data "$data")
  CODE="$(curl "${args[@]}" 2>/dev/null || echo 000)"
  BODY="$(cat "$body_file")"
  rm -f "$body_file"
}

# expect NAME WANT_CODE — checks CODE against the expected status
expect() {
  if [[ "$CODE" == "$2" ]]; then check "$1" 0 "(HTTP $CODE)"; else check "$1" 1 "(want HTTP $2, got $CODE: ${BODY:0:160})"; fi
}

jqr() { printf '%s' "$BODY" | jq -r "$1" 2>/dev/null; }

echo "$(ts) verify.sh against $BASE (run $RUN)"

# ---- 1. browser page routes (what a user opens; not covered by API calls) ----------
# page_check NAME PATH EXPECTED_CONTENT_TYPE_PREFIX: 200 with the right content type, sent like a browser.
page_check() {
  local name="$1" path="$2" want="$3" code ct
  code="$(curl -s -o /dev/null -m 20 -A "$BROWSER_UA" -H 'Accept: text/html,application/xhtml+xml,*/*;q=0.8' -w '%{http_code}' "$BASE$path")"
  ct="$(curl -s -o /dev/null -m 20 -A "$BROWSER_UA" -H 'Accept: text/html,application/xhtml+xml,*/*;q=0.8' -w '%{content_type}' "$BASE$path")"
  if [[ "$code" == 200 && "$ct" == "$want"* ]]; then
    check "page $name ($path) returns 200 $want" 0 "(HTTP $code, $ct)"
  else
    check "page $name ($path) returns 200 $want" 1 "(HTTP $code, $ct)"
  fi
}
page_check "home" / text/html
page_check "login" /login text/html
page_check "register" /register text/html
page_check "dashboard route" /dashboard text/html
page_check "deep SPA route" /projects/123 text/html
ASSET="$(curl -s -m 20 -A "$BROWSER_UA" "$BASE/" | grep -o 'src="[^"]*\.js"' | head -1 | sed 's/^src="//; s/"$//')"
if [[ -n "$ASSET" ]]; then
  page_check "static script from index.html" "$ASSET" application/javascript
else
  check "static script referenced by index.html" 1 "(no .js reference found)"
fi

req GET /health
expect "api health returns 200" 200
[[ "$(jqr .database)" == up ]] && check "api health reports database up" 0 "" || check "api health reports database up" 1 "(${BODY:0:120})"
cache_state="$(jqr .cache)"
check "api health reports cache state" 0 "(cache=$cache_state)"

# ---- 2. auth ----------------------------------------------------------------
A_EMAIL="verify-a-$RUN@example.test"
B_EMAIL="verify-b-$RUN@example.test"
PASSWORD="VerifyPass-$RUN"

req POST /auth/register "{\"name\":\"Verify Alice\",\"email\":\"$A_EMAIL\",\"password\":\"$PASSWORD\"}"
expect "register user A" 201
TOKEN_A="$(jqr .token)"

req POST /auth/register "{\"name\":\"Verify Bob\",\"email\":\"$B_EMAIL\",\"password\":\"$PASSWORD\"}"
expect "register user B" 201
TOKEN_B="$(jqr .token)"

req POST /auth/login "{\"email\":\"$A_EMAIL\",\"password\":\"$PASSWORD\"}"
expect "login user A" 200
TOKEN_A="$(jqr .token)"

req POST /auth/login "{\"email\":\"$A_EMAIL\",\"password\":\"wrong-password\"}"
expect "login with wrong password is rejected" 401

req GET /auth/me "" "$TOKEN_A"
expect "auth/me for user A" 200
A_ID="$(jqr .user.id)"
[[ "$(jqr .user.email)" == "$A_EMAIL" ]] && check "auth/me returns user A's email" 0 "" || check "auth/me returns user A's email" 1 ""

req GET /projects
expect "projects without a token is rejected" 401

req POST /auth/login '{"email":"manager@qt.rw","password":"Manager@123"}'
expect "login seeded manager" 200
TOKEN_M="$(jqr .token)"

req POST /auth/login '{"email":"admin@qt.rw","password":"Admin@123"}'
expect "login seeded admin" 200
TOKEN_ADMIN="$(jqr .token)"

# ---- 3. role rules ----------------------------------------------------------
req POST /projects "{\"name\":\"Verify forbidden $RUN\"}" "$TOKEN_A"
expect "member cannot create a project (role rule)" 403

# ---- 4. create and list (the app's equivalent of entries) -------------------
req POST /projects "{\"name\":\"Verify project $RUN\",\"description\":\"verify.sh\"}" "$TOKEN_M"
expect "manager creates a project" 201
PID="$(jqr .id)"

req POST "/projects/$PID/tasks" "{\"title\":\"Verify task $RUN\",\"priority\":\"high\"}" "$TOKEN_M"
expect "manager creates a task in the project" 201
TID="$(jqr .id)"

req GET /projects "" "$TOKEN_M"
expect "manager lists projects" 200
printf '%s' "$BODY" | jq -e --arg id "$PID" 'any(.[]; .id == $id)' >/dev/null && check "project appears in manager's list" 0 "" || check "project appears in manager's list" 1 ""

req GET "/projects/$PID/tasks" "" "$TOKEN_M"
expect "manager lists tasks of the project" 200
printf '%s' "$BODY" | jq -e --arg id "$TID" 'any(.[]; .id == $id)' >/dev/null && check "task appears in the project's list" 0 "" || check "task appears in the project's list" 1 ""

# ---- 5. isolation: users only see their own data ----------------------------
req GET /projects "" "$TOKEN_A"
expect "user A lists projects" 200
printf '%s' "$BODY" | jq -e --arg id "$PID" 'any(.[]; .id == $id) | not' >/dev/null && check "user A does not see the manager's project" 0 "" || check "user A does not see the manager's project" 1 ""

req GET "/projects/$PID" "" "$TOKEN_A"
expect "user A cannot open the manager's project (404, not 403)" 404

req GET "/projects/$PID/tasks" "" "$TOKEN_A"
expect "user A cannot list the project's tasks" 404

req PATCH "/tasks/$TID" '{"status":"done"}' "$TOKEN_A"
[[ "$CODE" == 403 || "$CODE" == 404 ]] && check "user A cannot change the task" 0 "(HTTP $CODE)" || check "user A cannot change the task" 1 "(HTTP $CODE)"

req GET /projects "" "$TOKEN_B"
printf '%s' "$BODY" | jq -e --arg id "$PID" 'any(.[]; .id == $id) | not' >/dev/null && check "user B does not see the project" 0 "" || check "user B does not see the project" 1 ""

# ---- 6. sharing grants access, and only to the shared user ------------------
req PUT "/projects/$PID" "{\"memberIds\":[\"$A_ID\"]}" "$TOKEN_M"
expect "manager adds user A to the project" 200

req GET /projects "" "$TOKEN_A"
printf '%s' "$BODY" | jq -e --arg id "$PID" 'any(.[]; .id == $id)' >/dev/null && check "user A now sees the shared project" 0 "" || check "user A now sees the shared project" 1 ""

req POST "/projects/$PID/tasks" "{\"title\":\"Shared task by A $RUN\"}" "$TOKEN_A"
expect "shared member cannot create tasks (owner or admin only)" 403

req GET "/projects/$PID" "" "$TOKEN_B"
expect "user B still cannot open the project after sharing with A" 404

req GET /projects "" "$TOKEN_ADMIN"
printf '%s' "$BODY" | jq -e --arg id "$PID" 'any(.[]; .id == $id)' >/dev/null && check "admin sees every project (documented rule)" 0 "" || check "admin sees every project (documented rule)" 1 ""

# ---- 6b. the origin rule stays on: an origin that is not listed is refused ---------
ORIGIN_SAVED="$ORIGIN"
ORIGIN="http://evil.example"
req POST /auth/login '{"email":"manager@qt.rw","password":"Manager@123"}'
expect "login from an unlisted origin is refused (no wildcard)" 403
ORIGIN="$ORIGIN_SAVED"

# ---- 7. cleanup of the test project ------------------------------------------
req DELETE "/projects/$PID" "" "$TOKEN_M"
expect "manager deletes the test project" 204
req GET "/projects/$PID" "" "$TOKEN_M"
expect "deleted project is gone" 404

echo "$(ts) SUMMARY passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
