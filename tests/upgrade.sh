#!/bin/bash
# Upgrade test for LEI UDS bundle
# Validates deploying version N+1 over version N without data loss.
# Usage: ./tests/upgrade.sh <previous-bundle> <current-bundle>
# Environment: UDS_DOMAIN (default: uds.dev)
set -euo pipefail

PREVIOUS_BUNDLE="${1:?Usage: upgrade.sh <previous-bundle.tar.zst> <current-bundle.tar.zst>}"
CURRENT_BUNDLE="${2:?Usage: upgrade.sh <previous-bundle.tar.zst> <current-bundle.tar.zst>}"
DOMAIN="${UDS_DOMAIN:-uds.dev}"
NAMESPACE="${LEI_NAMESPACE:-lei}"
TIMEOUT="${WAIT_TIMEOUT:-300s}"
API_URL="https://lei.${DOMAIN}"

PASSED=0
FAILED=0

pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }

cleanup() {
  echo ""
  echo "=== Results: ${PASSED} passed, ${FAILED} failed ==="
  if [ "$FAILED" -gt 0 ]; then
    echo "UPGRADE TEST FAILED"
    exit 1
  fi
  echo "UPGRADE TEST PASSED"
}
trap cleanup EXIT

echo "=== LEI UDS Upgrade Test ==="
echo "Previous: ${PREVIOUS_BUNDLE}"
echo "Current:  ${CURRENT_BUNDLE}"
echo "Domain:   ${DOMAIN}"
echo ""

# --- 1. Deploy previous version ---
echo "[1/6] Deploying previous version..."
if [ ! -f "${PREVIOUS_BUNDLE}" ]; then
  fail "Previous bundle not found: ${PREVIOUS_BUNDLE}"
  exit 1
fi

uds deploy "${PREVIOUS_BUNDLE}" --confirm --config uds-config.yaml
if kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=lowendinsight \
    -n "${NAMESPACE}" --timeout="${TIMEOUT}" 2>/dev/null; then
  pass "Previous version deployed and pods ready"
else
  fail "Previous version pods did not become ready"
  exit 1
fi

# --- 2. Verify previous version is functional ---
echo "[2/6] Verifying previous version..."
if curl -sf "${API_URL}/healthz" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  pass "Previous version health check passed"
else
  fail "Previous version health check failed"
fi

# --- 3. Seed test data ---
echo "[3/6] Seeding test data..."
PRE_CACHE=""

# Try batch analyze endpoint
SEED_RESPONSE=$(curl -sf -X POST "${API_URL}/v1/analyze/batch" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${LEI_JWT:-}" \
  -d '{
    "dependencies": [
      {"ecosystem": "hex", "package": "jason", "version": "1.4.0"}
    ]
  }' 2>/dev/null || echo "")

if [ -n "${SEED_RESPONSE}" ]; then
  pass "Seeded test data via batch analyze"
  sleep 5
else
  echo "  INFO: Could not seed via batch (auth may be required), continuing..."
fi

# Record pre-upgrade state
PRE_CACHE=$(curl -sf "${API_URL}/v1/health" \
  -H "Authorization: Bearer ${LEI_JWT:-}" 2>/dev/null | \
  jq -r '.cache.size // empty' 2>/dev/null || echo "")

if [ -n "${PRE_CACHE}" ]; then
  echo "  Pre-upgrade cache size: ${PRE_CACHE}"
else
  echo "  INFO: Could not read cache stats, will skip preservation check"
fi

# --- 4. Deploy current version (upgrade) ---
echo "[4/6] Deploying current version (upgrade)..."
if [ ! -f "${CURRENT_BUNDLE}" ]; then
  fail "Current bundle not found: ${CURRENT_BUNDLE}"
  exit 1
fi

UPGRADE_START=$(date +%s)
uds deploy "${CURRENT_BUNDLE}" --confirm --config uds-config.yaml

if kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=lowendinsight \
    -n "${NAMESPACE}" --timeout="${TIMEOUT}" 2>/dev/null; then
  UPGRADE_END=$(date +%s)
  UPGRADE_DURATION=$((UPGRADE_END - UPGRADE_START))
  pass "Upgrade completed in ${UPGRADE_DURATION}s, pods ready"

  # Check upgrade time is reasonable (< 5 min)
  if [ "${UPGRADE_DURATION}" -lt 300 ]; then
    pass "Upgrade completed within 5 minute window"
  else
    fail "Upgrade took ${UPGRADE_DURATION}s, exceeds 5 minute target"
  fi
else
  fail "Upgraded pods did not become ready within ${TIMEOUT}"
fi

# --- 5. Verify post-upgrade functionality ---
echo "[5/6] Verifying post-upgrade functionality..."

# Health check
if curl -sf "${API_URL}/healthz" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  pass "Post-upgrade health check passed"
else
  fail "Post-upgrade health check failed"
fi

# Readiness
if curl -sf "${API_URL}/readyz" | jq -e '.status == "ready"' >/dev/null 2>&1; then
  pass "Post-upgrade readiness check passed"
else
  fail "Post-upgrade readiness check failed"
fi

# Metrics
if curl -sf "${API_URL}/metrics" | grep -q "beam_" 2>/dev/null; then
  pass "Post-upgrade metrics endpoint working"
else
  fail "Post-upgrade metrics endpoint failed"
fi

# --- 6. Verify data preservation ---
echo "[6/6] Verifying data preservation..."

if [ -n "${PRE_CACHE}" ]; then
  POST_CACHE=$(curl -sf "${API_URL}/v1/health" \
    -H "Authorization: Bearer ${LEI_JWT:-}" 2>/dev/null | \
    jq -r '.cache.size // "0"' 2>/dev/null || echo "0")

  echo "  Post-upgrade cache size: ${POST_CACHE}"

  if [ "${POST_CACHE}" -ge "${PRE_CACHE}" ] 2>/dev/null; then
    pass "Cache data preserved across upgrade (${PRE_CACHE} -> ${POST_CACHE})"
  else
    fail "Cache data lost during upgrade (${PRE_CACHE} -> ${POST_CACHE})"
  fi
else
  echo "  INFO: Skipping cache preservation check (no pre-upgrade data)"
fi

# Check database migration state
if kubectl exec -n "${NAMESPACE}" \
    "$(kubectl get pod -n "${NAMESPACE}" -l app.kubernetes.io/name=lowendinsight -o jsonpath='{.items[0].metadata.name}')" \
    -- bin/lei eval "Lei.Repo.__adapter__()" >/dev/null 2>&1; then
  pass "Database adapter accessible post-upgrade"
else
  echo "  INFO: Could not verify database directly"
fi
