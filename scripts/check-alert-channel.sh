#!/usr/bin/env bash
#
# Can this repository page anyone?
#
# An alarm that cannot reach its channel is not an alarm, so this is checked
# before anything else in the monitor. But the channel is a third party, and a
# single unreachable probe is weather rather than an outage: on 2026-10-05 at
# 04:24 the probe returned HTTP 000 -- a connection curl could not make -- and
# the next fifteen runs all succeeded. That one blip paged a human about our own
# monitoring.
#
# So a transport failure is retried and a credential rejection is not. 401/403
# is deterministic: the token is wrong and will still be wrong in twenty
# seconds, and retrying only delays a page that needs sending.
#
# Reads the token on stdin, never as an argument.
set -uo pipefail

TOPIC="${NTFY_TOPIC:-}"
SERVER="${NTFY_SERVER:-https://ntfy.sh}"
ATTEMPTS="${ALERT_PROBE_ATTEMPTS:-3}"
GAP="${ALERT_PROBE_GAP:-10}"

TOKEN="$(cat)"

if [ -z "$TOKEN" ] || [ -z "$TOPIC" ]; then
  echo "::error::NTFY_TOKEN or NTFY_TOPIC is unset, so no check in this file can page anyone. Set them with: gh secret set NTFY_TOKEN"
  exit 1
fi

attempt=1
while : ; do
  STATUS=$(printf 'Authorization: Bearer %s\n' "$TOKEN" \
    | curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
      -H @- "${SERVER}/${TOPIC}/auth" || true)

  echo "ntfy auth probe ${attempt}/${ATTEMPTS}: HTTP ${STATUS:-no response}"

  case "$STATUS" in
    2??)
      echo "The alert channel accepts this token."
      exit 0
      ;;
    401|403)
      # Deterministic. Retrying a rejected credential wastes the only thing
      # that matters here, which is telling someone promptly.
      echo "::error::ntfy rejected the paging credential (HTTP ${STATUS}). Every page from this repository -- monitor, deploy and backup -- is going nowhere, and each one still reports having sent it. Rotate the token and set it over stdin: gh secret set NTFY_TOKEN"
      exit 1
      ;;
    *)
      if [ "$attempt" -ge "$ATTEMPTS" ]; then
        # Still the rule everywhere else in this file: an answer we could not
        # get is not a reassuring one. Three failures a ${GAP}s apart is a
        # channel that is down, not a blip.
        echo "::error::Could not reach ntfy in ${ATTEMPTS} attempts (last: HTTP ${STATUS:-no response}). Whether a page would arrive is unknown."
        exit 1
      fi
      attempt=$((attempt + 1))
      sleep "$GAP"
      ;;
  esac
done
