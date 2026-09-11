#!/usr/bin/env bash
# Unified smoke test for LEI deployments.
# Used by GLITCHLAB ops-org and keiro Uplink agent.
# Usage: ./scripts/smoke-test.sh [BASE_URL]

set -euo pipefail

BASE_URL="${1:-https://lowendinsight.dev}"
PASS=0
FAIL=0
TOTAL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }

check() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    green "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    red "  FAIL: $desc (expected: $expected, got: $actual)"
    FAIL=$((FAIL + 1))
  fi
}

check_contains() {
  TOTAL=$((TOTAL + 1))
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    green "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    red "  FAIL: $desc (expected to contain: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

bold "=== LEI Smoke Test: $BASE_URL ==="
echo ""

# --- 1. Core health ---
bold "1. Health check"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/")
check "GET / returns 200" "200" "$STATUS"

BODY=$(curl -s --max-time 10 "$BASE_URL/")
check_contains "Homepage contains LowEndInsight" "LowEndInsight" "$BODY"

# --- 2. Static assets ---
bold "2. Static assets"
IMG_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/images/lei_bus_128.png")
check "Bus logo serves" "200" "$IMG_STATUS"

DOC_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/doc")
check "GET /doc returns 200" "200" "$DOC_STATUS"

# --- 3. Auth enforcement ---
bold "3. Auth enforcement (no token → 401)"
NO_AUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST "$BASE_URL/v1/analyze" \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://github.com/kitplummer/xmpp4rails"]}')
check "POST /v1/analyze without auth returns 401" "401" "$NO_AUTH"

FAKE_KEY=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/cache/stats" \
  -H "Authorization: Bearer lei_00000000000000000000000000000000")
check "Fake lei_ key returns 401" "401" "$FAKE_KEY"

# --- 4. API key ---
# Signing up creates a real org every run. That is acceptable occasionally but
# corrosive as a deploy gate or on a schedule, so a provided key is preferred
# and signup is only exercised when explicitly asked for.
#
#   LEI_SMOKE_API_KEY  use this key, skip signup (no org created)
#   LEI_SMOKE_FULL     force the signup flow even when a key is provided
if [ -n "${LEI_SMOKE_API_KEY:-}" ] && [ "${LEI_SMOKE_FULL:-false}" != "true" ]; then
  bold "4. API key (provided — signup skipped, no org created)"
  API_KEY="$LEI_SMOKE_API_KEY"

  WHOAMI=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/usage" \
    -H "Authorization: Bearer $API_KEY")
  check "Provided API key is accepted" "200" "$WHOAMI"

  if [ "$WHOAMI" != "200" ]; then
    red "  FATAL: LEI_SMOKE_API_KEY was rejected — aborting authenticated tests"
    echo ""
    bold "=== Results: $PASS passed, $FAIL failed out of $TOTAL ==="
    exit 1
  fi
  echo "  Using key: ${API_KEY:0:12}..."
else
  bold "4. Signup flow (creates an org)"
  SIGNUP_PAGE=$(curl -s --max-time 10 "$BASE_URL/signup")
  check_contains "Signup page loads" "Create an Organization" "$SIGNUP_PAGE"

  SIGNUP_RESP=$(curl -s -X POST "$BASE_URL/signup" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "name=smoke-test-$(date +%s)&tier=free" \
    -L --max-time 15)
  check_contains "Signup returns API key" "lei_" "$SIGNUP_RESP"
  check_contains "Signup returns recovery code" "lei_recover_" "$SIGNUP_RESP"

  API_KEY=$(echo "$SIGNUP_RESP" | grep -oP 'lei_[a-f0-9]{32}' | head -1)
  if [ -z "$API_KEY" ]; then
    red "  FATAL: Could not extract API key — aborting authenticated tests"
    echo ""
    bold "=== Results: $PASS passed, $FAIL failed out of $TOTAL ==="
    exit 1
  fi
  echo "  Got API key: ${API_KEY:0:12}..."
fi

# --- 4b. Authenticated single analyze ---
# This is the primary documented endpoint, and the suite only ever checked that
# it rejects anonymous callers. It raised on every *authenticated* request for
# as long as the rate limiter existed, because the limiter built its ETS table
# in init/1 -- which Plug resolves at compile time.
bold "4b. Authenticated POST /v1/analyze"
ANALYZE_RESP=$(curl -s -X POST "$BASE_URL/v1/analyze" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  --max-time 60 \
  -d '{"urls":["https://github.com/kitplummer/xmpp4rails"]}')

if echo "$ANALYZE_RESP" | grep -q "POSTful service"; then
  red "  FAIL: POST /v1/analyze returned the generic error handler (it raised)"
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
else
  green "  PASS: POST /v1/analyze did not raise"
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi

# Deliberately no assertion on the response *shape*. cache_mode defaults to
# "blocking" with a 30s timeout, so a cold-cache miss returns a different
# payload than a hit. Asserting on that made the deploy gate reject a working
# fix. "Did not raise" is the regression guard; the shape is not stable enough
# to gate on.

# --- 5. Batch analyze with billing ---
bold "5. Batch analyze with billing"
BATCH_RESP=$(curl -s -X POST "$BASE_URL/v1/analyze/batch" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  --max-time 30 \
  -d '{"dependencies": [{"ecosystem": "npm", "package": "express", "version": "4.18.2"}, {"ecosystem": "npm", "package": "lodash", "version": "4.17.21"}]}')
check_contains "Response has billing block" "billing" "$BATCH_RESP"
check_contains "Billing has cost_cents" "cost_cents" "$BATCH_RESP"
check_contains "Billing has tier" '"tier"' "$BATCH_RESP"

# --- 6. Usage endpoint ---
bold "6. Usage endpoint"
sleep 1
USAGE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer $API_KEY")
check "GET /v1/usage returns 200" "200" "$USAGE_STATUS"

USAGE_RESP=$(curl -s --max-time 10 "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer $API_KEY")
check_contains "Usage has period_start" "period_start" "$USAGE_RESP"
check_contains "Usage has total_cost_cents" "total_cost_cents" "$USAGE_RESP"
check_contains "Usage has cache_hits" "cache_hits" "$USAGE_RESP"

USAGE_NO_AUTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.invalid")
check "GET /v1/usage without API key returns 401" "401" "$USAGE_NO_AUTH"

# --- 7. Dashboard ---
bold "7. Dashboard"
curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "api_key=$API_KEY" \
  -c /tmp/lei-smoke-cookies \
  -L --max-time 10 > /dev/null
DASH_RESP=$(curl -s "$BASE_URL/dashboard" \
  -b /tmp/lei-smoke-cookies \
  -L --max-time 10)
check_contains "Dashboard has Cache Hits" "Cache Hits" "$DASH_RESP"
check_contains "Dashboard has Total Cost" "Total Cost" "$DASH_RESP"
rm -f /tmp/lei-smoke-cookies

# --- 8. Ops endpoints (regression guard: these all 404'd or 401'd in prod) ---
bold "8. Ops endpoints"

# Unauthenticated platform probes. Fly http_checks and Kubernetes liveness /
# readiness probes depend on these answering without credentials.
HEALTHZ=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/healthz")
check "GET /healthz returns 200" "200" "$HEALTHZ"

READYZ=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/readyz")
check "GET /readyz returns 200" "200" "$READYZ"

METRICS_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/metrics")
check "GET /metrics returns 200" "200" "$METRICS_STATUS"

METRICS_BODY=$(curl -s --max-time 10 "$BASE_URL/metrics")
check_contains "Metrics are Prometheus format" "beam_memory_bytes" "$METRICS_BODY"
check_contains "Metrics include cache gauge" "lei_cache_entries_total" "$METRICS_BODY"

# /v1/health sits under the /v1 prefix but must answer unauthenticated.
V1_HEALTH=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$BASE_URL/v1/health")
check "GET /v1/health returns 200 without auth" "200" "$V1_HEALTH"

# /v1/orgs routing. An unknown slug must produce the router's own "org not
# found", not the endpoint catch-all — that is what distinguishes a routed
# request from an unreachable one, since both return 404.
ORGS_BODY=$(curl -s --max-time 10 "$BASE_URL/v1/orgs/definitely-not-a-real-org/keys" \
  -H "Authorization: Bearer $API_KEY")
check_contains "GET /v1/orgs/:slug/keys reaches the router" "org not found" "$ORGS_BODY"

# --- Summary ---
echo ""
bold "=== Results: $PASS passed, $FAIL failed out of $TOTAL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  green "All tests passed!"
  exit 0
fi
