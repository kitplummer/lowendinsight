#!/usr/bin/env bash
#
# Proves STRIPE_WEBHOOK_SECRET is the right one for the registered endpoint.
#
#   scripts/verify-webhook-secret.sh [base_url]
#
# A wrong signing secret fails exactly like an unset one from the outside:
# every delivery 400s, subscriptions quietly stop activating, and nothing else
# changes (BILLING_SETUP.md section 3). The only thing that distinguishes them
# is a real delivery, so this sends one and reads the counters either side.
#
# Read-only until the resend, which is announced before it happens. The event
# is chosen to be one the handler ignores: signature verification runs before
# the handler looks at the type, so an unhandled event proves the secret
# without activating an org or touching the ledger.
#
# Exit codes: 0 verified, 1 refused or not verified, 2 bad usage or missing
# prerequisite. "Could not tell" is always an error, never a pass.

set -uo pipefail

case "${1:-}" in
  -h | --help)
    sed -n '2,20p' "$0" | sed 's/^#\{0,1\} \{0,1\}//'
    exit 0
    ;;
esac

BASE_URL="${1:-https://lowendinsight.dev}"
HOST="${BASE_URL#https://}"
HOST="${HOST#http://}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
dim() { printf '\033[2m%s\033[0m\n' "$1"; }
die() { red "$1"; exit "${2:-1}"; }

for tool in stripe jq curl; do
  command -v "$tool" >/dev/null || die "$tool is required but not installed" 2
done

# The seven types Lei.StripeWebhookHandler acts on -- and, not by coincidence,
# exactly the seven the endpoint subscribes to.
#
# That makes "safe to resend" and "will actually be delivered" disjoint sets,
# which is the trap the first version of this script fell into: it picked an
# event the handler ignores, Stripe accepted the resend, and nothing was
# delivered because the endpoint was not subscribed to that type.
# BILLING_SETUP section 3: "An event the endpoint is not subscribed to is never
# delivered, and nothing reports its absence."
#
# So the endpoint is subscribed to a harmless type for the length of one
# redelivery, and put back. Nothing new is created in Stripe -- an existing
# event is redelivered -- and the handler ignores the type, while the counter
# this measures is recorded on signature verification, before the handler runs
# (router.ex, Lei.WebhookStats.record(:ok)).
HANDLED='checkout.session.completed checkout.session.async_payment_succeeded
         customer.subscription.deleted invoice.payment_failed charge.refunded
         charge.dispute.funds_withdrawn charge.dispute.funds_reinstated'

counters() {
  curl -s --max-time 15 "$BASE_URL/metrics" \
    | grep '^lei_stripe_webhook_total' \
    | sed -E 's/lei_stripe_webhook_total\{result="([a-z]+)"\} ([0-9]+)/\1=\2/'
}

counter() { echo "$1" | grep "^$2=" | cut -d= -f2; }

uptime_s() {
  curl -s --max-time 15 "$BASE_URL/v1/health" | jq -r '.uptime_seconds // empty'
}

# --- 1. the endpoint Stripe is actually sending to -------------------------

bold "1. Registered endpoint"

ENDPOINTS=$(stripe get /v1/webhook_endpoints 2>/dev/null) \
  || die "could not reach Stripe -- is the CLI logged in for the right account?"

echo "$ENDPOINTS" | jq -r '.data[] | "  \(.id)  \(.url)  \(.status)  \(.enabled_events | length) events"'

WE_ID=$(echo "$ENDPOINTS" | jq -r --arg h "$HOST" \
  '[.data[] | select(.url | contains($h))][0].id // empty')

[ -n "$WE_ID" ] || die "no webhook endpoint registered for $HOST -- nothing would ever be delivered"

WE_STATUS=$(echo "$ENDPOINTS" | jq -r --arg id "$WE_ID" '.data[] | select(.id==$id) | .status')
[ "$WE_STATUS" = "enabled" ] || die "endpoint $WE_ID is '$WE_STATUS', so Stripe is not delivering to it"

ORIGINAL=$(echo "$ENDPOINTS" | jq -c --arg id "$WE_ID" '.data[] | select(.id==$id) | .enabled_events')
green "  using $WE_ID"
echo

# --- 2. an existing event of a type the handler ignores --------------------

bold "2. Choosing an event to redeliver"

EVENTS=$(stripe get /v1/events --limit 50 2>/dev/null) || die "could not list events"

CHOSEN=$(echo "$EVENTS" | jq -r --arg handled "$(echo $HANDLED)" '
  ($handled | split(" ")) as $h
  | [.data[] | select(.type as $t | ($h | index($t)) | not)][0] // empty
  | "\(.id) \(.type)"')

if [ -z "$CHOSEN" ]; then
  red "  No event of an unhandled type exists to redeliver."
  dim "  Create one -- it is a sandbox object with no effect here -- then re-run:"
  dim "      stripe trigger payment_intent.created"
  exit 1
fi

EVT_ID=${CHOSEN%% *}
EVT_TYPE=${CHOSEN#* }
echo "  $EVT_ID  ($EVT_TYPE)"
dim "  The handler ignores this type, so verification is all that will happen."
echo

# --- subscription, restored whatever happens -------------------------------

subscribe_to() {
  local events_json="$1" args=()
  while read -r e; do args+=(-d "enabled_events[]=$e"); done < <(echo "$events_json" | jq -r '.[]')
  stripe post "/v1/webhook_endpoints/$WE_ID" "${args[@]}" >/dev/null 2>&1
}

restore() {
  subscribe_to "$ORIGINAL"
  local now
  now=$(stripe get "/v1/webhook_endpoints/$WE_ID" 2>/dev/null | jq -c '.enabled_events')
  if [ "$now" = "$ORIGINAL" ]; then
    dim "  subscription restored ($(echo "$ORIGINAL" | jq 'length') events)"
  else
    red "  SUBSCRIPTION NOT RESTORED -- expected $ORIGINAL, got $now"
    red "  Put it back before relying on webhooks."
  fi
}

# --- 3. counters before ----------------------------------------------------

BEFORE=$(counters)
[ -n "$BEFORE" ] || die "$BASE_URL/metrics published no webhook counters; cannot measure anything"

UP_BEFORE=$(uptime_s)
[ -n "$UP_BEFORE" ] || die "could not read uptime; a restart mid-test would reset the counters unnoticed"

bold "3. Counters before"
echo "$BEFORE" | sed 's/^/  /'
echo

# --- 4. deliver ------------------------------------------------------------

bold "4. Redelivering $EVT_ID"

trap restore EXIT

TEMP=$(echo "$ORIGINAL" | jq -c --arg t "$EVT_TYPE" '. + [$t]')
subscribe_to "$TEMP" || die "could not update the endpoint's subscription"

SUBSCRIBED=$(stripe get "/v1/webhook_endpoints/$WE_ID" 2>/dev/null | jq '.enabled_events | length')
dim "  subscribed to $EVT_TYPE for this redelivery ($SUBSCRIBED events)"

stripe events resend "$EVT_ID" --webhook-endpoint="$WE_ID" >/dev/null 2>&1
RESEND_RC=$?

if [ $RESEND_RC -ne 0 ]; then
  red "  Stripe refused to resend (exit $RESEND_RC)."
  exit 1
fi

green "  redelivery accepted"
echo

# --- 5. counters after -----------------------------------------------------

bold "5. Waiting for the delivery to land"

AFTER=""
for attempt in $(seq 1 10); do
  CURRENT=$(counters)

  # An empty read is a failed scrape, not a result. Retrying is right; using
  # it as "after" would compare nothing against something and call it a change.
  if [ -n "$CURRENT" ]; then
    AFTER="$CURRENT"
    if [ "$AFTER" != "$BEFORE" ]; then
      printf '  a counter moved after %ss\n' "$(( (attempt - 1) * 2 ))"
      break
    fi
  fi

  printf '  waiting (%s/10)\r' "$attempt"
  sleep 2
done
printf '                    \r'

[ -n "$AFTER" ] || die "could not read the counters back; nothing was measured"

if [ "$AFTER" = "$BEFORE" ]; then
  dim "  no counter moved within 20s"
fi

UP_AFTER=$(uptime_s)
if [ -n "$UP_AFTER" ] && [ "$UP_AFTER" -lt "${UP_BEFORE:-0}" ]; then
  die "the application restarted during the test; counters reset on boot, so this proved nothing"
fi

echo "$AFTER" | sed 's/^/  /'
echo

delta() { echo $(( $(counter "$AFTER" "$1") - $(counter "$BEFORE" "$1") )); }

OK=$(delta ok)
INVALID=$(delta invalid)
UNCONFIGURED=$(delta unconfigured)
STALE=$(delta stale)

bold "=== Result ==="

if [ "${OK:-0}" -gt 0 ]; then
  green "VERIFIED: the delivery was signed, and the secret on the running app matches."
  exit 0
elif [ "${INVALID:-0}" -gt 0 ]; then
  red "WRONG SECRET: the signature did not verify."
  dim "STRIPE_WEBHOOK_SECRET is set but belongs to a different endpoint. Each"
  dim "endpoint has its own. Copy $WE_ID's signing secret from the Dashboard:"
  dim "    read -rs S && printf 'STRIPE_WEBHOOK_SECRET=%s\\n' \"\$S\" | flyctl secrets import -a lowendinsight && unset S"
  exit 1
elif [ "${UNCONFIGURED:-0}" -gt 0 ]; then
  red "NOT SET: Stripe signed the delivery and the running app has no secret to check it with."
  exit 1
elif [ "${STALE:-0}" -gt 0 ]; then
  red "STALE: the signature was too old to accept. Check the clock on the host."
  exit 1
else
  red "NOTHING ARRIVED: no counter moved, so the delivery never reached the application."
  dim "That is not a secret problem -- it is reachability or routing. Check what"
  dim "status Stripe recorded for the attempt:"
  dim "    stripe get /v1/events/$EVT_ID | jq '.request, .pending_webhooks'"
  exit 1
fi
