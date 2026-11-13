#!/usr/bin/env bash
#
# Starts the backup producer and reports what it did.
#
#   APP=lowendinsight-backup FLY_API_TOKEN=... scripts/ops/backup-trigger.sh
#
# Run by .github/workflows/backup-trigger.yml, which says why the schedule
# lives in GitHub rather than Fly. Exit codes: 0 the producer ran and exited 0,
# 1 anything else, including "could not tell".
set -uo pipefail

APP="${APP:?APP is required}"
# Overridable so the tests do not wait five real minutes.
POLL="${BACKUP_POLL_SECONDS:-5}"
POLLS="${BACKUP_WAIT_POLLS:-60}"

if [ -z "${FLY_API_TOKEN:-}" ]; then
  echo "::error::FLY_BACKUP_TOKEN is not set, so no backup was started. Create one with: flyctl tokens create deploy -a lowendinsight-backup"
  exit 1
fi

# Discovered, not hardcoded. The machine is recreated whenever a secret
# changes -- a machine takes its secrets at creation -- and it has been
# recreated four times in two days. A hardcoded id becomes a trigger
# that starts nothing and says nothing.
ID=$(flyctl machine list -a "$APP" --json 2>/dev/null \
  | jq -r '(map(select(.config.schedule != null)) + .)[0].id // empty')

if [ -z "$ID" ]; then
  echo "::error::No machine found in ${APP}. The producer does not exist; see ops/backup/README.md to create it."
  exit 1
fi
echo "machine: ${ID}"

# The newest exit event before we start anything.
#
# The machine is already `stopped` when we begin -- that is its resting
# state -- so a wait loop that only asks "is it stopped?" can be
# satisfied by the state it was already in, and then read the *previous*
# run's exit code. A prior success would mask a fresh failure. So the
# condition is a new exit event, not a state.
#
# Prints the newest exit timestamp, 0 when the machine shows none. A read that
# fails prints nothing and returns 1, so it cannot pass for an answer.
exits() {
  local out
  out=$(flyctl machine list -a "$APP" --json 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er --arg id "$ID" \
    '[.[] | select(.id == $id) | (.events // [])[] | select(.type == "exit") | .timestamp] | max // 0'
}

# Without a baseline every exit event looks new, the previous run's included.
BEFORE=""
for _ in 1 2 3; do
  BEFORE=$(exits) && break
  BEFORE=""
  sleep "$POLL"
done

if [ -z "$BEFORE" ]; then
  echo "::error::Could not read ${ID}'s exit events before starting it, so a new run could not be told from the last one. Nothing was started."
  exit 1
fi
echo "newest exit event before starting: ${BEFORE}"

flyctl machine start "$ID" -a "$APP" \
  || { echo "::error::Could not start ${ID}."; exit 1; }

# Wait for it to finish. The dump takes a few seconds; on-failure
# allows up to three attempts, so allow for those too.
#
# Only a later exit is the new one. Different is not enough: on 2026-11-06
# and 2026-11-12, just after the start, the machine's events no longer showed
# the old exit, the newest read as 0, the wait ended after one poll, and the
# exit code was read before the dump had finished. A failed read is retried.
AFTER=""
POLLED=0

while [ "$POLLED" -lt "$POLLS" ]; do
  sleep "$POLL"
  POLLED=$(( POLLED + 1 ))
  if AFTER=$(exits) && [ "$AFTER" -gt "$BEFORE" ] 2>/dev/null; then
    break
  fi
  AFTER=""
done

echo "newest exit event after: ${AFTER:-none newer} (waited $(( POLLED * POLL ))s)"

if [ -z "$AFTER" ]; then
  echo "::error::${ID} produced no new exit event in five minutes, so this run has not finished and may not have started. Whether a backup was taken is unknown; check: flyctl logs -a ${APP}"
  exit 1
fi

# backup.sh exits non-zero on every failure it can detect: an empty
# dump, one it cannot read back, an artifact that will not decrypt, an
# upload that did not land. So the exit code is the result.
#
# Read from the newest exit event. `machine list --json` omits the exit
# code; the status table carries it.
CODE=$(flyctl machine status "$ID" -a "$APP" 2>/dev/null \
  | grep -m1 "exit_code=" \
  | sed -n 's/.*exit_code=\([0-9]*\).*/\1/p')

echo "exit code: ${CODE:-unreadable}"

if [ -z "$CODE" ]; then
  echo "::error::Could not read an exit code for ${ID}. It ran, and whether the backup succeeded is unknown -- which is not the same as fine."
  exit 1
fi

if [ "$CODE" != "0" ]; then
  echo "::error::The producer exited ${CODE}: the backup failed. Its own log says why, and it has already paged. Check: flyctl logs -a ${APP}"
  exit 1
fi

echo "The producer ran and exited 0."
