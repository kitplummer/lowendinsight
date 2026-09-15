#!/usr/bin/env bash
#
# Exercises the web UI's actual journeys against a running deployment.
#
#   scripts/canary.sh [BASE_URL]
#
# Every layer beneath the Analyze button was tested and green when it hung
# forever in production: find_binary_files had unit tests, the route had tests,
# CI passed, the deploy gate passed, the 15-minute monitor passed. What nobody
# asserted was "clicking Analyze produces a report".
#
# Two things make this different from the existing smoke test, and both are
# load-bearing.
#
# It runs against a deployment. The bug was a GNU-vs-BusyBox grep difference:
# the analysis completed in 793ms locally and never returned in production. A
# suite running on a CI runner has GNU grep and tests an environment the bug
# cannot exist in.
#
# It defeats the cache. /url= reads Redis before analysing, with a 30-day TTL.
# A canary that analyses the same repository every deploy misses once, goes
# green, and then hits cache forever -- staying green while the analysis is
# completely broken. That is this codebase's signature failure, so the check
# built to catch it must not be built that way.

set -uo pipefail

BASE_URL="${1:-https://lowendinsight.dev}"
CANARY_REPO="${CANARY_REPO:-https://github.com/kitplummer/lita-cron}"

# Long enough for a cold clone and analysis, short enough that a hang fails
# rather than hanging the job. The observed cold path is a few seconds.
ANALYZE_TIMEOUT="${CANARY_ANALYZE_TIMEOUT:-90}"

PASS=0
FAIL=0

green() { printf '\033[32m  PASS\033[0m %s\n' "$1"; }
red()   { printf '\033[31m  FAIL\033[0m %s\n' "$1"; }
bold()  { printf '\033[1m%s\033[0m\n' "$1"; }

ok()  { green "$1"; PASS=$((PASS + 1)); }
bad() { red "$1"; [ -n "${2:-}" ] && echo "         $2"; FAIL=$((FAIL + 1)); }

# Asserts on content, not status. /gh_trending returned 200 with an empty
# report and a fabricated UUID for months; a status code is not evidence that a
# feature works.
contains() {
  local name="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    ok "$name"
  else
    bad "$name" "expected to find: ${needle}"
  fi
}

encoded_repo() {
  python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$CANARY_REPO"
}

bold "=== canary against ${BASE_URL} ==="
echo "repo: ${CANARY_REPO}"
echo

# --- the page itself -------------------------------------------------------

bold "the page loads"

HOME_BODY=$(curl -s --max-time 15 "$BASE_URL/")
contains "homepage renders" "LowEndInsight" "$HOME_BODY"
contains "homepage has the analyze form" 'id="form"' "$HOME_BODY"
contains "homepage credits the operator" "(r)evolve" "$HOME_BODY"

# The homepage is how an agent learns it can pay rather than sign up, and
# /llms.txt is the same guide for agents that read markdown. Both are rendered
# from live configuration; a regression to the old page would tell agents
# nothing about the 402 they will receive.
contains "homepage tells agents how to pay" "no account needed" "$HOME_BODY"
contains "homepage links the agent guide" 'href="/llms.txt"' "$HOME_BODY"

LLMS_BODY=$(curl -s --max-time 15 "$BASE_URL/llms.txt")
contains "llms.txt describes the payment challenge" "WWW-Authenticate: Payment" "$LLMS_BODY"

# The form does nothing without its JavaScript, and a 404 on it is silent in
# the browser -- the button simply stops responding.
#
# The list is read out of the page rather than hardcoded here. A fixed list is
# how backup.yml came to verify four table names while missing the fifth: it
# keeps passing, correctly, about the wrong things.
ASSETS=$(printf '%s' "$HOME_BODY" \
  | grep -oE '(src|href)="/[^"]+"' \
  | sed -E 's/^(src|href)="//; s/"$//' \
  | sort -u)

if [ -z "$ASSETS" ]; then
  bad "page references local destinations" "found none — the page may not have rendered"
else
  for asset in $ASSETS; do
    STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL$asset")
    if [ "$STATUS" = "200" ]; then
      ok "reachable ${asset}"
    else
      bad "reachable ${asset}" "status ${STATUS} — a dead link or asset on the main page"
    fi
  done
fi
echo

# Browsers request /favicon.ico from the root regardless of what the page says,
# so no link tag points at it and the scan above can never cover it.
FAVICON=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/favicon.ico")
[ "$FAVICON" = "200" ] && ok "/favicon.ico serves" \
  || bad "/favicon.ico serves" "status ${FAVICON}"
echo

# --- validation ------------------------------------------------------------

bold "url validation"

ENCODED=$(encoded_repo)
VALID_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  "$BASE_URL/validate-url/url=${ENCODED}")
[ "$VALID_STATUS" = "200" ] && ok "a real repo validates" \
  || bad "a real repo validates" "status ${VALID_STATUS}"

JUNK=$(python3 -c "import urllib.parse;print(urllib.parse.quote('not-a-url',safe=''))")
JUNK_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  "$BASE_URL/validate-url/url=${JUNK}")
[ "$JUNK_STATUS" != "200" ] && ok "junk is rejected" \
  || bad "junk is rejected" "validation accepted 'not-a-url'"
echo

# --- the journey -----------------------------------------------------------

bold "analyze"

# Without this the check degrades into a test of Redis. Skipped rather than
# failed when no admin key is configured, but said out loud -- a silent
# downgrade to a weaker check is how this goes stale.
INVALIDATED=0

if [ -n "${LEI_ADMIN_API_KEY:-}" ]; then
  INVALIDATE=$(curl -s -w '\n%{http_code}' --max-time 15 -X POST \
    "$BASE_URL/v1/cache/invalidate" \
    -H "Authorization: Bearer ${LEI_ADMIN_API_KEY}" \
    -H 'Content-Type: application/json' \
    -d "{\"url\":\"${CANARY_REPO}\"}")

  INVALIDATE_STATUS=$(printf '%s' "$INVALIDATE" | tail -1)

  if [ "$INVALIDATE_STATUS" = "200" ]; then
    ok "cache invalidated, so the analysis is real work"
    INVALIDATED=1
  else
    bad "cache invalidated" "status ${INVALIDATE_STATUS} — the analysis below may be a cache hit"
  fi
elif [ "${CANARY_STRICT:-0}" = "1" ]; then
  # In CI this is a failure, not a note. Without invalidation the analysis
  # check can be satisfied by a cached report, which means the canary passes
  # while the thing it exists to test is broken.
  bad "cache invalidated" "LEI_ADMIN_API_KEY is not set and CANARY_STRICT=1"
else
  echo "  ---- LEI_ADMIN_API_KEY unset: not invalidating."
  echo "       The analysis check below may be satisfied by a cached report."
fi

# The failure was a hang, not an error, so the timeout is the assertion. curl
# exits non-zero and reports 000 on timeout.
START=$(date +%s)
REPORT=$(curl -s --max-time "$ANALYZE_TIMEOUT" "$BASE_URL/url=${ENCODED}")
CURL_RC=$?
ELAPSED=$(( $(date +%s) - START ))

if [ "$CURL_RC" -ne 0 ]; then
  bad "analyze returns within ${ANALYZE_TIMEOUT}s" \
      "curl exit ${CURL_RC} after ${ELAPSED}s — this is the hang that shipped once"
elif [ "$INVALIDATED" -eq 0 ] && [ "$ELAPSED" -lt 2 ]; then
  # Returning instantly with no invalidation means Redis answered. The analysis
  # path was not exercised, so this is not a pass -- reporting it as one is the
  # precise failure this canary exists to prevent.
  bad "analyze exercises the analysis" \
      "returned in ${ELAPSED}s without invalidation — that is a cache hit, not an analysis"
else
  ok "analyze returns (${ELAPSED}s)"

  # A report, not merely a response. An empty shell would satisfy a status check.
  contains "report names the repo" "$CANARY_REPO" "$REPORT"
  contains "report has a risk value" '"risk":' "$REPORT"

  if printf '%s' "$REPORT" | grep -qE '"risk":"(critical|high|medium|low)"'; then
    ok "risk is a real level"
  else
    bad "risk is a real level" "found no critical/high/medium/low"
  fi

  if printf '%s' "$REPORT" | grep -q '"contributor_count":0'; then
    bad "report has contributors" "contributor_count is 0 — the git analysis did nothing"
  else
    ok "report has contributors"
  fi
fi
echo

# --- the other buttons on the page ----------------------------------------

bold "the other main-page destinations"

DOC_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$BASE_URL/doc")
[ "$DOC_STATUS" = "200" ] && ok "manual loads" || bad "manual loads" "status ${DOC_STATUS}"

TRENDING=$(curl -s --max-time 60 "$BASE_URL/gh_trending/elixir")
TRENDING_RC=$?

if [ "$TRENDING_RC" -ne 0 ]; then
  bad "trending returns" "curl exit ${TRENDING_RC}"
else
  ok "trending returns"

  # This check used to grep the page for "github.com" -- and matched the
  # Source link in the page chrome, so it passed while every trending report
  # was an empty placeholder (#158). It now reads what the report contains:
  # one row per analysed repository, each a script element carrying
  # `data-repo="<url>"`. (Rows used to assign `var project = "<url>"`; that
  # markup went when report fields stopped being written into script source.)
  ROWS=$(printf '%s' "$TRENDING" | grep -oE 'data-repo="https?://' | wc -l | tr -d ' ')
  COMPLETED=$(curl -s --max-time 15 "$BASE_URL/metrics" \
    | grep 'lei_trending_report_completed{language="elixir"}' | awk '{print $2}' | tr -d '\r')

  if [ "${COMPLETED:-}" = "1" ]; then
    if [ "${ROWS:-0}" -gt 0 ]; then
      ok "trending shows analysed repositories (${ROWS})"
    else
      bad "trending shows analysed repositories" "a completed report is recorded but the page has no repository rows"
    fi
  else
    # Not failed here in either mode. A deploy can precede the first hourly
    # refresh, and a rollback over that would never let the fix ship; and
    # freshness is already the monitor's "Check trending reports are fresh"
    # step, from lei_trending_report_age_seconds. Said out loud, not passed.
    echo "  ---- no completed elixir trending report (completed=${COMPLETED:-absent});"
    echo "       freshness is enforced by the monitor's trending step, not here."
  fi
fi
echo

# --- an agent that has never been here --------------------------------------

bold "an agent can pay"

# The payment path was built, deployed and green for two releases while no
# agent could reach it: the endpoint's auth plug answered 401 before anything
# behind it ran (#147). What an agent actually sees is the only proof.
#
# Each run issues one challenge row; unanswered challenges are reaped.
AGENT_HEADERS=$(mktemp)
AGENT_STATUS=$(curl -s -o /dev/null -D "$AGENT_HEADERS" -w '%{http_code}' --max-time 20 \
  -X POST "$BASE_URL/v1/analyze" -H 'content-type: application/json' \
  -d "{\"urls\":[\"${CANARY_REPO}\"]}")

[ "$AGENT_STATUS" = "402" ] \
  && ok "an unauthenticated analysis is asked to pay" \
  || bad "an unauthenticated analysis is asked to pay" "status ${AGENT_STATUS}"

if grep -qi '^www-authenticate: Payment .*method="tempo"' "$AGENT_HEADERS"; then
  ok "the 402 offers stablecoin"
else
  bad "the 402 offers stablecoin" "no WWW-Authenticate: Payment challenge with method=\"tempo\""
fi
rm -f "$AGENT_HEADERS"
echo

# --- payments mode ---------------------------------------------------------

bold "stripe mode"

# The mode is derived from the key the deployment actually holds, so this is
# the only place a half-flipped cutover is visible without taking a payment.
# STRIPE_EXPECTED_MODE is the workflows' statement of intent; flipping it is
# part of the cutover, and forgetting to fails here loudly rather than quietly.
READYZ=$(curl -s --max-time 15 "$BASE_URL/readyz")
MODE=$(printf '%s' "$READYZ" | jq -r '.stripe_mode // "absent"' 2>/dev/null || echo "unparseable")
STRIPE_CHECK=$(printf '%s' "$READYZ" | jq -r '.checks.stripe // "absent"' 2>/dev/null || echo "unparseable")

if [ -n "${STRIPE_EXPECTED_MODE:-}" ]; then
  [ "$MODE" = "$STRIPE_EXPECTED_MODE" ] \
    && ok "serving in ${MODE} mode" \
    || bad "serving in ${STRIPE_EXPECTED_MODE} mode" "readyz reports stripe_mode=${MODE}"
else
  # A manual run with no expectation still refuses a mode that is not a mode.
  case "$MODE" in
    test|live) ok "serving in a real mode (${MODE}; set STRIPE_EXPECTED_MODE to assert which)" ;;
    *) bad "serving in a real mode" "readyz reports stripe_mode=${MODE}" ;;
  esac
fi

# Configuration faults fail. "unreachable" and "pending" do not: a Stripe
# outage during a deploy must not roll back a good release. Monitoring still
# fails on them, because they make readiness degraded.
case "$STRIPE_CHECK" in
  ok) ok "configured prices exist in ${MODE} mode" ;;
  pending|unreachable) ok "stripe objects not yet confirmed (${STRIPE_CHECK}); monitor will retry" ;;
  *) bad "configured prices exist in ${MODE} mode" "readyz checks.stripe=${STRIPE_CHECK}" ;;
esac
echo

# --- nothing secret on what is served -------------------------------------

bold "no secrets on public pages"

# Reports published the application environment -- Stripe keys and signing
# secrets -- on these pages for months while every check here was green
# (security, 2026-09-14). This reads what the deployment serves. The scanner
# prints pattern names, never matched text. An empty body fails: a page that
# could not be fetched was not scanned, and must not count as clean.
SCAN_DIR="$(cd "$(dirname "$0")" && pwd)"

scan_body() {
  local label="$1" body="$2" out rc
  out=$(printf '%s' "$body" | "$SCAN_DIR/secret-scan.sh" "$label" 2>&1)
  rc=$?
  case "$rc" in
    0) ok "no secrets: ${label}" ;;
    1) bad "no secrets: ${label}" "$out" ;;
    *) bad "no secrets: ${label}" "nothing to scan (empty response)" ;;
  esac
}

scan_body "home page" "$HOME_BODY"
scan_body "llms.txt" "$LLMS_BODY"
scan_body "Try It report" "${REPORT:-}"
scan_body "trending (elixir)" "${TRENDING:-}"
scan_body "readyz" "${READYZ:-}"

for path in /gh_trending /doc /openapi.json /metrics /signup /login; do
  scan_body "$path" "$(curl -s --max-time 30 "$BASE_URL$path")"
done
echo

# --- result ----------------------------------------------------------------

bold "=== ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

# A canary that checked nothing is not a passing canary.
if [ "$PASS" -eq 0 ]; then
  red "No checks ran at all."
  exit 1
fi

green "The UI works."
