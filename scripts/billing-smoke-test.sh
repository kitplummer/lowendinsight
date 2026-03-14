#!/usr/bin/env bash
# Functional smoke test for cache-tiered usage tracking & metered billing
# Usage: ./scripts/billing-smoke-test.sh [BASE_URL]

set -euo pipefail

BASE_URL="${1:-https://lowendinsight.fly.dev}"
PASS=0
FAIL=0
TOTAL=0

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }

check() {
  TOTAL=$((TOTAL + 1))
  local desc="$1"
  local expected="$2"
  local actual="$3"
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
  local desc="$1"
  local needle="$2"
  local haystack="$3"
  if echo "$haystack" | grep -q "$needle"; then
    green "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    red "  FAIL: $desc (expected to contain: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

bold "=== Billing Smoke Test: $BASE_URL ==="
echo ""

# --- Test 1: Health check ---
bold "1. Health check"
STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/")
check "GET / returns 200" "200" "$STATUS"

# --- Test 2: Free tier signup ---
bold "2. Free tier signup"
SIGNUP_RESP=$(curl -s -X POST "$BASE_URL/signup" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "name=smoke-test-billing-$(date +%s)&tier=free" \
  -L)
check_contains "Signup returns API key" "lei_" "$SIGNUP_RESP"
check_contains "Signup returns recovery code" "lei_recover_" "$SIGNUP_RESP"

# Extract the API key from the response
API_KEY=$(echo "$SIGNUP_RESP" | grep -oP 'lei_[a-f0-9]{32}' | head -1)
if [ -z "$API_KEY" ]; then
  red "  FATAL: Could not extract API key from signup response"
  echo "Results: $PASS passed, $FAIL failed out of $TOTAL"
  exit 1
fi
echo "  Got API key: ${API_KEY:0:12}..."

# --- Test 3: Batch analyze with billing info ---
bold "3. Batch analyze returns billing block"
BATCH_RESP=$(curl -s -X POST "$BASE_URL/v1/analyze/batch" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d '{"dependencies": [{"ecosystem": "npm", "package": "express", "version": "4.18.2"}, {"ecosystem": "npm", "package": "lodash", "version": "4.17.21"}]}')
check_contains "Response has billing block" "billing" "$BATCH_RESP"
check_contains "Billing has cost_cents" "cost_cents" "$BATCH_RESP"
check_contains "Billing has tier" '"tier"' "$BATCH_RESP"
check_contains "Billing shows free tier" '"free"' "$BATCH_RESP"

# --- Test 4: GET /v1/usage ---
bold "4. Usage endpoint"
# Small delay for async usage recording
sleep 1
USAGE_RESP=$(curl -s "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer $API_KEY")
USAGE_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer $API_KEY")
check "GET /v1/usage returns 200" "200" "$USAGE_STATUS"
check_contains "Usage has period_start" "period_start" "$USAGE_RESP"
check_contains "Usage has cache_hits" "cache_hits" "$USAGE_RESP"
check_contains "Usage has cache_misses" "cache_misses" "$USAGE_RESP"
check_contains "Usage has total_cost_cents" "total_cost_cents" "$USAGE_RESP"
check_contains "Usage shows free tier" '"free"' "$USAGE_RESP"
echo "  Usage response: $USAGE_RESP"

# --- Test 5: Usage endpoint requires API key (not JWT) ---
bold "5. Usage endpoint rejects JWT-only"
USAGE_JWT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/v1/usage" \
  -H "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.e30.invalid")
# Should get 401 (either from auth or from usage endpoint)
check "GET /v1/usage without API key returns 401" "401" "$USAGE_JWT_STATUS"

# --- Test 6: Dashboard shows usage ---
bold "6. Dashboard shows usage stats"
# Login first
LOGIN_RESP=$(curl -s -X POST "$BASE_URL/login" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "api_key=$API_KEY" \
  -c /tmp/lei-smoke-cookies \
  -L)
DASH_RESP=$(curl -s "$BASE_URL/dashboard" \
  -b /tmp/lei-smoke-cookies \
  -L)
check_contains "Dashboard has Cache Hits" "Cache Hits" "$DASH_RESP"
check_contains "Dashboard has Cache Misses" "Cache Misses" "$DASH_RESP"
check_contains "Dashboard has Total Cost" "Total Cost" "$DASH_RESP"
check_contains "Dashboard has Free Tier info" "Free Tier" "$DASH_RESP"
rm -f /tmp/lei-smoke-cookies

# --- Test 7: Pro signup page works ---
bold "7. Signup page offers Pro tier"
SIGNUP_PAGE=$(curl -s "$BASE_URL/signup")
check_contains "Signup page loads" "Create an Organization" "$SIGNUP_PAGE"

# --- Summary ---
echo ""
bold "=== Results: $PASS passed, $FAIL failed out of $TOTAL ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
else
  green "All tests passed!"
  exit 0
fi
