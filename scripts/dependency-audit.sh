#!/usr/bin/env bash
#
# Fails on any known advisory in a locked dependency that has not been
# acknowledged, with a reason, in scripts/acknowledged-advisories.txt.
#
#   scripts/dependency-audit.sh            # PRs and preflight
#   scripts/dependency-audit.sh --strict   # the daily run (.github/workflows/audit.yml)
#
# `mix deps.audit` (mix_audit) reported "No vulnerabilities found" while the
# lock held HIGH advisories in plug, cowboy, cowlib, postgrex and hackney: its
# advisory database did not have them. `mix hex.audit` reads Hex's own advisory
# data. This script also fails when:
#   - an acknowledged advisory no longer matches (the ignore list must shrink),
#     with --strict only. Without it that is a warning: the advisory database
#     revising an advisory to "fixed in the version we lock" is good news, and
#     it failed main on 2026-09-16 with no code change. The daily --strict run
#     still makes the list shrink.
#   - Hex is too old to check advisories, or the audit printed nothing
#     recognisable, so the check examined nothing

set -uo pipefail
cd "$(dirname "$0")/.."

STRICT=0
case "${1:-}" in
  "") ;;
  --strict) STRICT=1 ;;
  *) echo "usage: $0 [--strict]"; exit 2 ;;
esac

ACK="scripts/acknowledged-advisories.txt"
[ -f "$ACK" ] || { echo "FAIL: $ACK is missing"; exit 1; }

# Every entry needs a reason, or the list becomes a place to hide findings.
if grep -vE '^\s*(#|$)' "$ACK" | grep -vqE '^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)* # .{10,}$'; then
  echo "FAIL: every entry in $ACK must be '<ID>[,<ID>...] # <reason>':"
  grep -vE '^\s*(#|$)' "$ACK" | grep -vE '^[A-Za-z0-9-]+(,[A-Za-z0-9-]+)* # .{10,}$'
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
  if [ "$STRICT" -eq 1 ]; then
    echo "FAIL: an acknowledged advisory no longer applies; remove it from scripts/acknowledged-advisories.txt"
    exit 1
  fi
  # A GitHub Actions annotation, so it shows on the PR without failing it.
  echo "::warning::An acknowledged advisory no longer applies; remove it from scripts/acknowledged-advisories.txt (the daily --strict audit fails until it is)"
  STALE_ACK=1
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

# mix_audit reads GitHub's advisory database, which Hex's does not always
# mirror. Run it too, with the same acknowledgements.
MIX_AUDIT=$(MIX_ENV=test mix deps.audit --ignore-advisory-ids "$IDS" 2>&1)
MIX_AUDIT_STATUS=$?
printf '%s\n' "$MIX_AUDIT"
if [ "$MIX_AUDIT_STATUS" -ne 0 ]; then
  echo "FAIL: mix_audit found unacknowledged vulnerabilities (above)"
  exit 1
fi
printf '%s\n' "$MIX_AUDIT" | grep -q "No vulnerabilities found" || {
  echo "FAIL: mix_audit did not report a result; it may not have run"
  exit 1
}

if [ "${STALE_ACK:-0}" -eq 1 ]; then
  echo "Dependency audit passed: no unacknowledged advisories (with a stale acknowledgement, above)."
else
  echo "Dependency audit passed: no unacknowledged advisories."
fi
