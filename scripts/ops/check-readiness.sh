#!/usr/bin/env bash
#
# Production readiness, as the monitor checks it.
#
#   scripts/ops/check-readiness.sh [BASE_URL]
#
# "degraded" means a dependency is down while the app still serves -- the
# exact state that went unnoticed for months. Moved out of monitor.yml so it can
# run under scripts/ops/confirm.sh like the other production probes.
set -uo pipefail

BASE_URL="${1:-https://lowendinsight.dev}"

BODY=$(curl -s --max-time 15 "${BASE_URL}/readyz")
CURL_RC=$?
echo "readyz: ${BODY:-<no response, curl exit ${CURL_RC}>}"

STATUS=$(jq -r '.status // "unreachable"' <<<"$BODY" 2>/dev/null)
STATUS=${STATUS:-unreachable}

case "$STATUS" in
  ok)
    echo "All dependencies healthy."
    ;;
  degraded)
    FAILING=$(jq -r '.checks | to_entries[] | select(.value != "ok") | .key' <<<"$BODY" | paste -sd, -)
    echo "::error::Production is DEGRADED. Failing dependencies: ${FAILING}. The app is still serving, which is why nothing else will tell you."
    exit 1
    ;;
  *)
    echo "::error::Production readiness is '${STATUS}'. Response: ${BODY:-none (curl exit ${CURL_RC})}"
    exit 1
    ;;
esac
