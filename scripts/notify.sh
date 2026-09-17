#!/usr/bin/env bash
#
# Sends one operations notification through ntfy.
#
#   scripts/notify.sh --title TEXT [--priority 1-5] [--tags a,b] [--click URL] MESSAGE
#
# Requires NTFY_TOKEN and NTFY_TOPIC; NTFY_SERVER defaults to https://ntfy.sh.
# Priority: 5 urgent, 4 high, 3 default, 2 low, 1 min.
#
# A notifier that cannot notify must not look like one that did: missing
# configuration exits 2 and a post ntfy did not accept exits 1, so the step
# calling it fails visibly instead of the alert quietly going nowhere.
#
# The token never appears on a command line: it reaches curl as a header read
# from stdin, so it is not in the process list or a CI log. Messages carry no
# customer data -- say what is wrong, which runbook applies, and link to the run.

set -uo pipefail

SERVER="${NTFY_SERVER:-https://ntfy.sh}"
TITLE="" PRIORITY="3" TAGS="" CLICK=""

fail() { printf 'notify: %s\n' "$2" >&2; exit "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --title) TITLE="${2:-}"; shift 2 ;;
    --priority) PRIORITY="${2:-}"; shift 2 ;;
    --tags) TAGS="${2:-}"; shift 2 ;;
    --click) CLICK="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) fail 2 "unknown option: $1" ;;
    *) break ;;
  esac
done

MESSAGE="${*:-}"

[ -n "${NTFY_TOKEN:-}" ] || fail 2 "NTFY_TOKEN is not set: this alert would go nowhere"
[ -n "${NTFY_TOPIC:-}" ] || fail 2 "NTFY_TOPIC is not set: this alert would go nowhere"
[ -n "$TITLE" ] || fail 2 "--title is required"
[ -n "$MESSAGE" ] || fail 2 "a message is required"
[[ "$PRIORITY" =~ ^[1-5]$ ]] || fail 2 "--priority must be 1-5"
[[ "$NTFY_TOPIC" =~ ^[A-Za-z0-9_-]{1,64}$ ]] || fail 2 "NTFY_TOPIC is not a valid topic name"

headers() {
  printf 'Authorization: Bearer %s\n' "$NTFY_TOKEN"
  printf 'Title: %s\n' "$TITLE"
  printf 'Priority: %s\n' "$PRIORITY"
  [ -n "$TAGS" ] && printf 'Tags: %s\n' "$TAGS"
  [ -n "$CLICK" ] && printf 'Click: %s\n' "$CLICK"
  return 0
}

status=$(headers | curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
  -H @- --data-binary "$MESSAGE" "${SERVER}/${NTFY_TOPIC}")

case "$status" in
  2??) printf 'notify: sent (%s)\n' "$status" >&2 ;;
  *) fail 1 "ntfy did not accept the notification (HTTP ${status:-no response})" ;;
esac
