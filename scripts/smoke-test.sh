#!/bin/bash
# Smoke test for LEI live environment — auth, account, and API coverage
#
# Usage:
#   ./scripts/smoke-test.sh [base_url]
#   LEI_JWT_SECRET=<secret> ./scripts/smoke-test.sh [base_url]
#
# Set LEI_JWT_SECRET to test authenticated endpoints.
# Without it, only auth-rejection and public endpoint tests run.

BASE_URL="${1:-https://lowendinsight.fly.dev}"
PASS=0
FAIL=0
SKIP=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo "  PASS: $name (got $actual)"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected $expected, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

skip() {
  echo "  SKIP: $1"
  SKIP=$((SKIP + 1))
}

# Generate a JWT if secret is available
JWT=""
if [ -n "${LEI_JWT_SECRET:-}" ]; then
  # HS256 JWT: header.payload.signature
  header=$(echo -n '{"alg":"HS256","typ":"JWT"}' | base64 -w0 | tr '+/' '-_' | tr -d '=')
  # exp = now + 1 hour
  exp=$(( $(date +%s) + 3600 ))
  payload=$(echo -n "{\"sub\":\"smoke-test\",\"exp\":$exp}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
  sig=$(echo -n "$header.$payload" | openssl dgst -sha256 -hmac "$LEI_JWT_SECRET" -binary | base64 -w0 | tr '+/' '-_' | tr -d '=')
  JWT="$header.$payload.$sig"
  echo "JWT generated for authenticated tests"
else
  echo "No LEI_JWT_SECRET set — authenticated endpoint tests will be skipped"
fi

echo ""
echo "=== LEI Smoke Tests against $BASE_URL ==="

# ─── Section 1: Public Endpoints (no auth) ───

echo ""
echo "--- Public Endpoints ---"

echo "[1] Root / UI"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/")
check "GET / returns 200" "200" "$code"

echo "[2] OpenAPI spec"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/openapi.json")
check "GET /openapi.json returns 200" "200" "$code"

echo "[3] API docs page"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/doc")
check "GET /doc returns 200" "200" "$code"

# ─── Section 2: Auth Enforcement (no token) ───

echo ""
echo "--- Auth Enforcement (no token → 401) ---"

echo "[4] POST /v1/analyze without auth"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$BASE_URL/v1/analyze" \
  -H "Content-Type: application/json" \
  -d '{"urls":["https://github.com/kitplummer/xmpp4rails"]}')
check "Returns 401" "401" "$code"

echo "[5] GET /v1/analyze/:uuid without auth"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/analyze/00000000-0000-0000-0000-000000000000")
check "Returns 401" "401" "$code"

echo "[6] GET /v1/cache/stats without auth"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats")
check "Returns 401" "401" "$code"

echo "[7] GET /v1/cache/export without auth"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/export")
check "Returns 401" "401" "$code"

echo "[8] POST /v1/cache/import without auth"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$BASE_URL/v1/cache/import" \
  -H "Content-Type: application/json" -d '{}')
check "Returns 401" "401" "$code"

# ─── Section 3: Bad Token Rejection ───

echo ""
echo "--- Bad Token Rejection ---"

echo "[9] Invalid JWT"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats" \
  -H "Authorization: Bearer invalidtoken123")
check "Bad JWT returns 401" "401" "$code"

echo "[10] Malformed auth header"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats" \
  -H "Authorization: Token abc123")
check "Non-Bearer auth returns 401" "401" "$code"

echo "[11] Empty Bearer"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats" \
  -H "Authorization: Bearer ")
check "Empty Bearer returns 401" "401" "$code"

echo "[12] Fake API key (lei_ prefix)"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats" \
  -H "Authorization: Bearer lei_00000000000000000000000000000000")
check "Fake lei_ key returns 401" "401" "$code"

# ─── Section 4: Malformed Requests ───

echo ""
echo "--- Malformed Requests ---"

echo "[13] POST /v1/analyze with bad JSON"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$BASE_URL/v1/analyze" \
  -H "Content-Type: application/json" -d 'not json')
check "Bad JSON returns 400 or 401" "true" \
  "$([ "$code" = "400" ] || [ "$code" = "401" ] && echo true || echo false)"

echo "[14] Unknown route"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/nonexistent")
check "Unknown /v1 route returns 401 or 404" "true" \
  "$([ "$code" = "404" ] || [ "$code" = "401" ] && echo true || echo false)"

# ─── Section 5: Lei.Web.Router (org/key API — not started in prod) ───

echo ""
echo "--- Org/Key API (Lei.Web.Router — expected not running) ---"

echo "[15] GET /healthz (Lei.Web.Router liveness)"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/healthz")
# If Lei.Web.Router isn't running, this will 404 from the main endpoint
check "GET /healthz returns 200 or 404" "true" \
  "$([ "$code" = "200" ] || [ "$code" = "404" ] && echo true || echo false)"

echo "[16] POST /v1/orgs (org management)"
code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$BASE_URL/v1/orgs" \
  -H "Content-Type: application/json" -d '{"name":"smoke-test"}')
check "POST /v1/orgs returns 401 or 404" "true" \
  "$([ "$code" = "401" ] || [ "$code" = "404" ] && echo true || echo false)"

# ─── Section 6: Authenticated Endpoints (requires LEI_JWT_SECRET) ───

echo ""
echo "--- Authenticated Endpoints ---"

if [ -n "$JWT" ]; then
  echo "[17] GET /v1/cache/stats with valid JWT"
  resp=$(curl -s -w "\n%{http_code}" --max-time 10 "$BASE_URL/v1/cache/stats" \
    -H "Authorization: Bearer $JWT")
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | head -1)
  check "Returns 200" "200" "$code"

  echo "[18] POST /v1/analyze with valid JWT"
  resp=$(curl -s -w "\n%{http_code}" --max-time 30 -X POST "$BASE_URL/v1/analyze" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d '{"urls":["https://github.com/kitplummer/xmpp4rails"]}')
  code=$(echo "$resp" | tail -1)
  body=$(echo "$resp" | sed '$d')
  check "Returns 200 or 202" "true" \
    "$([ "$code" = "200" ] || [ "$code" = "202" ] && echo true || echo false)"
  # Check response has expected structure
  if echo "$body" | grep -q '"uuid"'; then
    check "Response contains uuid" "true" "true"
  elif echo "$body" | grep -q '"report"'; then
    check "Response contains report" "true" "true"
  else
    check "Response has expected structure" "true" "false"
  fi

  echo "[19] GET /v1/cache/export with valid JWT"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$BASE_URL/v1/cache/export" \
    -H "Authorization: Bearer $JWT")
  check "Returns 200" "200" "$code"

  echo "[20] POST /v1/analyze/sbom with valid JWT (empty SBOM)"
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST "$BASE_URL/v1/analyze/sbom" \
    -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" \
    -d '{"sbom":"{}"}')
  check "Returns 200 or 400 or 422" "true" \
    "$([ "$code" = "200" ] || [ "$code" = "400" ] || [ "$code" = "422" ] && echo true || echo false)"
else
  skip "[17-20] Authenticated endpoint tests (set LEI_JWT_SECRET to run)"
fi

echo ""
echo "========================================="
echo "  Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "========================================="
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
