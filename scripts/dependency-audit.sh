#!/usr/bin/env bash
#
# Fails on any known advisory in a locked dependency that has not been
# acknowledged, with a reason, in scripts/acknowledged-advisories.txt.
#
#   scripts/dependency-audit.sh
#
# `mix deps.audit` (mix_audit) reported "No vulnerabilities found" while the
# lock held HIGH advisories in plug, cowboy, cowlib, postgrex and hackney: its
# advisory database did not have them. `mix hex.audit` reads Hex's own advisory
# data. This script also fails when:
#   - an acknowledged advisory no longer matches (the ignore list must shrink)
#   - Hex is too old to check advisories, or the audit printed nothing
#     recognisable, so the check examined nothing

set -uo pipefail
cd "$(dirname "$0")/.."

ACK="scripts/acknowledged-advisories.txt"
[ -f "$ACK" ] || { echo "FAIL: $ACK is missing"; exit 1; }

# Every entry needs a reason, or the list becomes a place to hide findings.
if grep -vE '^\s*(#|$)' "$ACK" | grep -vqE '^[A-Za-z0-9-]+ # .{10,}$'; then
  echo "FAIL: every entry in $ACK must be '<ID> # <reason>':"
  grep -vE '^\s*(#|$)' "$ACK" | grep -vE '^[A-Za-z0-9-]+ # .{10,}$'
  exit 1
fi
IDS=$(grep -vE '^\s*(#|$)' "$ACK" | awk '{print $1}' | paste -sd, -)

# The mix.exs `hex: [ignore_advisories:]` option is not honoured from the
# umbrella root (Hex 2.5.1); the environment variable is.
OUT=$(HEX_IGNORE_ADVISORIES="$IDS" mix hex.audit 2>&1)
STATUS=$?
printf '%s\n' "$OUT"
echo

if printf '%s\n' "$OUT" | grep -q "does not match any advisory"; then
  echo "FAIL: an acknowledged advisory no longer applies; remove it from scripts/acknowledged-advisories.txt"
  exit 1
fi

if [ "$STATUS" -ne 0 ]; then
  echo "FAIL: dependencies with unacknowledged advisories or retirements (above)"
  exit 1
fi

# An old Hex without advisory support exits 0 having checked only
# retirements. Require a version that checks advisories.
HEX_VERSION=$(mix hex.info 2>/dev/null | sed -n 's/^Hex: *//p')
if [ -z "$HEX_VERSION" ] || ! printf '2.5.0\n%s\n' "$HEX_VERSION" | sort -VC; then
  echo "FAIL: Hex '${HEX_VERSION:-unknown}' does not check security advisories (need >= 2.5.0)"
  exit 1
fi

echo "Dependency audit passed: no unacknowledged advisories."
