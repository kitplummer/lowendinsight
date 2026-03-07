#!/bin/bash
# Journey test for LEI UDS deployment
# Validates the complete deployment lifecycle per UDS package requirements.
# Usage: ./tests/journey.sh
# Environment: UDS_DOMAIN (default: uds.dev)
set -euo pipefail

DOMAIN="${UDS_DOMAIN:-uds.dev}"
NAMESPACE="${LEI_NAMESPACE:-lei}"
TIMEOUT="${WAIT_TIMEOUT:-300s}"
API_URL="https://lei.${DOMAIN}"

PASSED=0
FAILED=0
WARNINGS=0

pass() { echo "  PASS: $1"; PASSED=$((PASSED + 1)); }
fail() { echo "  FAIL: $1"; FAILED=$((FAILED + 1)); }
warn() { echo "  WARN: $1"; WARNINGS=$((WARNINGS + 1)); }

cleanup() {
  echo ""
  echo "=== Results: ${PASSED} passed, ${FAILED} failed, ${WARNINGS} warnings ==="
  if [ "$FAILED" -gt 0 ]; then
    echo "JOURNEY TEST FAILED"
    exit 1
  fi
  echo "JOURNEY TEST PASSED"
}
trap cleanup EXIT

echo "=== LEI UDS Journey Test ==="
echo "Domain: ${DOMAIN}"
echo "Namespace: ${NAMESPACE}"
echo ""

# --- 1. Pod readiness ---
echo "[1/7] Pod status"
if kubectl wait --for=condition=ready pod \
    -l app.kubernetes.io/name=lowendinsight \
    -n "${NAMESPACE}" --timeout="${TIMEOUT}" 2>/dev/null; then
  pass "LEI pods are ready"
else
  fail "LEI pods did not become ready within ${TIMEOUT}"
fi

# --- 2. UDS Package CR ---
echo "[2/7] UDS Package CR"
PHASE=$(kubectl get package lei -n "${NAMESPACE}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
if [ "${PHASE}" = "Ready" ]; then
  pass "UDS Package CR phase is Ready"
elif [ -n "${PHASE}" ]; then
  fail "UDS Package CR phase is '${PHASE}', expected 'Ready'"
else
  warn "UDS Package CR not found (may not be using UDS operator)"
fi

# --- 3. Istio VirtualService ---
echo "[3/7] Istio networking"
VS_HOST=$(kubectl get virtualservice -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].spec.hosts[0]}' 2>/dev/null || echo "")
if echo "${VS_HOST}" | grep -q "lei"; then
  pass "VirtualService routes to lei host: ${VS_HOST}"
else
  warn "No VirtualService found for lei (Istio may not be configured)"
fi

# --- 4. NetworkPolicies ---
echo "[4/7] Network policies"
NP_COUNT=$(kubectl get networkpolicy -n "${NAMESPACE}" --no-headers 2>/dev/null | wc -l)
if [ "${NP_COUNT}" -gt 0 ]; then
  pass "Found ${NP_COUNT} network policies"
else
  warn "No network policies found in namespace ${NAMESPACE}"
fi

# --- 5. SSO / Keycloak ---
echo "[5/7] SSO configuration"
if kubectl get secret -n "${NAMESPACE}" 2>/dev/null | grep -q "sso"; then
  pass "SSO secret found"
else
  warn "SSO secret not found (Keycloak client may not be provisioned)"
fi

# --- 6. ServiceMonitor ---
echo "[6/7] Monitoring"
if kubectl get servicemonitor -n "${NAMESPACE}" --no-headers 2>/dev/null | grep -q "lei"; then
  pass "ServiceMonitor found for LEI"
else
  warn "No ServiceMonitor found (Prometheus operator may not be installed)"
fi

# --- 7. API functional tests ---
echo "[7/7] API functional tests"

# Health check
if curl -sf "${API_URL}/healthz" | jq -e '.status == "ok"' >/dev/null 2>&1; then
  pass "GET /healthz returns ok"
else
  fail "GET /healthz failed"
fi

# Readiness
if curl -sf "${API_URL}/readyz" | jq -e '.status == "ready"' >/dev/null 2>&1; then
  pass "GET /readyz returns ready"
else
  fail "GET /readyz failed"
fi

# Metrics
if curl -sf "${API_URL}/metrics" | grep -q "beam_"; then
  pass "GET /metrics returns BEAM metrics"
else
  fail "GET /metrics failed or missing BEAM metrics"
fi

# Health with cache stats
if curl -sf "${API_URL}/v1/health" -H "Authorization: Bearer ${LEI_JWT:-}" 2>/dev/null | jq -e '.cache' >/dev/null 2>&1; then
  pass "GET /v1/health returns cache stats"
else
  warn "GET /v1/health not accessible (auth may be required)"
fi
