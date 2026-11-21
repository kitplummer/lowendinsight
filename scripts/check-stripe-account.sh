#!/usr/bin/env bash
# Can the Stripe account take charges and pay out?
#
# A hold switches those off independently, and nothing else watching
# production can see either: a held account answers every read /readyz makes,
# and paused payouts change no other signal at all. Money keeps arriving, the
# ledger reconciles, and none of it reaches the bank. The response is in
# apps/lei_service/docs/OPERATIONS.md, "Stripe places the account on hold".
#
# Reads /metrics on stdin, so it can be tested by execution rather than by
# grepping the workflow that calls it.
#
#   ./scripts/check-stripe-account.sh < metrics.txt
#
# Enforced in live mode only. Until cutover production runs a sandbox key, and
# an account not yet activated for live payments reports both flags false while
# sandbox payments work; failing on that would page every 15 minutes for a
# state we chose. In every mode, metrics that are absent fail: an absent check
# reads exactly like a clean one.
#
# Exit 0 when the account can charge and pay out (or the mode is not live),
# 1 otherwise.

set -uo pipefail

METRICS=$(cat)
RUNBOOK='apps/lei_service/docs/OPERATIONS.md, "Stripe places the account on hold"'

gauge() { echo "$METRICS" | sed -n "$1" | head -1; }

MODE=$(gauge 's/^lei_stripe_mode{mode="\([a-z_]*\)"} 1$/\1/p')
if [ -z "$MODE" ]; then
  echo "::error::/metrics does not publish lei_stripe_mode, so whether a hold would matter cannot be decided."
  exit 1
fi

CHECK=$(gauge 's/^lei_stripe_account{measure="check",result="\([a-z_]*\)"} 1$/\1/p')
if [ -z "$CHECK" ]; then
  echo "::error::/metrics does not publish lei_stripe_account, so a Stripe account hold cannot be seen. The deployed release predates the check, or the collector stopped."
  exit 1
fi

CHARGES=$(gauge 's/^lei_stripe_account{measure="charges_enabled"} \([01]\)$/\1/p')
PAYOUTS=$(gauge 's/^lei_stripe_account{measure="payouts_enabled"} \([01]\)$/\1/p')
REASON=$(gauge 's/^lei_stripe_account{measure="disabled",reason="\([a-z0-9_.]*\)"} 1$/\1/p')

echo "stripe mode: ${MODE}  account read: ${CHECK}  charges_enabled=${CHARGES:-unread}  payouts_enabled=${PAYOUTS:-unread}  disabled_reason=${REASON:-none}"

if [ "$MODE" != "live" ]; then
  echo "Not live, so the account's flags are reported and not enforced."
  exit 0
fi

if [ "$CHECK" != "ok" ]; then
  echo "::error::The Stripe account could not be read (${CHECK}), so a hold would be invisible. 'unauthorized' means the key may not read the account; give it that permission."
  exit 1
fi

FAILED=0

if [ "$CHARGES" != "1" ]; then
  echo "::error::The Stripe account cannot take charges (charges_enabled=${CHARGES:-absent}, reason ${REASON:-none}). Every rail is taking requests it cannot settle. Switch the paths off and follow ${RUNBOOK}."
  FAILED=1
fi

if [ "$PAYOUTS" != "1" ]; then
  echo "::error::Stripe payouts are paused (payouts_enabled=${PAYOUTS:-absent}, reason ${REASON:-none}). Charges may still work, but nothing reaches the bank. Do not switch rails off for this alone; see ${RUNBOOK}."
  FAILED=1
fi

exit "$FAILED"
