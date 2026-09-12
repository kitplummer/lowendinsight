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

TRENDING=$(curl -s --max-time 60 "$BASE_URL/gh_trending")
TRENDING_RC=$?

if [ "$TRENDING_RC" -ne 0 ]; then
  bad "trending returns" "curl exit ${TRENDING_RC}"
else
  ok "trending returns"
  # Trending returned 200 with an empty report and a fabricated UUID for
  # months. Presence of the page is not evidence it found anything.
  if printf '%s' "$TRENDING" | grep -qE 'github\.com'; then
    ok "trending names real repositories"
  else
    bad "trending names real repositories" "no github.com links in the page"
  fi
fi
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
