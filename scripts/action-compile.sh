#!/usr/bin/env bash
#
# `mix compile` for the GitHub Action, with a time limit.
#
#   scripts/action-compile.sh          (run from the project to compile)
#
# On #353's lei-sarif run the action's cold build printed "Waiting for lock on
# the build directory (held by process 2498)" and waited until the job's
# 30-minute timeout cancelled it (#354). The next attempt on the same cold key
# passed, and so did 36 deliberate cold builds, so the cause is not known. A
# user's workflow would wait as long as its own job timeout allows: six hours
# by default.
#
# A cold build takes about a minute. Past LEI_COMPILE_TIMEOUT seconds (600)
# this prints the process tree and the lock holder -- the evidence #354 lacks
# -- kills the compile and fails. It never retries: a retry would turn an
# unexplained deadlock into a slower pass, and the next one would leave
# nothing behind to explain it.
set -uo pipefail

LIMIT="${LEI_COMPILE_TIMEOUT:-600}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

# Its own process group, so a hang can be killed whole: the BEAM, and
# anything it started. Without setsid (not on every runner) only the compile
# and its direct children are killed.
COMPILE='set -o pipefail; mix compile 2>&1 | tee "$0"'
if command -v setsid >/dev/null; then
  setsid bash -c "$COMPILE" "$LOG" &
  GROUP=1
else
  bash -c "$COMPILE" "$LOG" &
  GROUP=0
fi
PID=$!

elapsed=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$elapsed" -ge "$LIMIT" ]; then
    echo "::error::mix compile did not finish in ${LIMIT}s. A cold build takes about a minute, so this is a hang; see https://github.com/kitplummer/lowendinsight/issues/354 and add what follows to it."

    echo "== lock messages"
    grep 'Waiting for lock' "$LOG" || echo "(none)"

    holder=$(sed -n 's/.*held by process \([0-9][0-9]*\).*/\1/p' "$LOG" | tail -1)
    if [ -n "$holder" ]; then
      echo "== lock holder $holder"
      ps -o pid,ppid,pgid,stat,etime,args -p "$holder" || echo "(no longer running)"
      # In this compile's process group means the compile is waiting on
      # itself, not on another build.
      if [ "$(ps -o pgid= -p "$holder" 2>/dev/null | tr -d ' ')" = "$PID" ]; then
        echo "the holder is inside this compile's process group"
      fi
    fi

    # This compile's process group, and every BEAM on the runner: the lock
    # holder is one of them. Not the whole machine: this goes into a log that
    # may be public, and another process's arguments can hold a token.
    echo "== this compile"
    ps -o pid,ppid,pgid,stat,etime,args --forest -g "$PID" 2>/dev/null || echo "(gone)"
    echo "== BEAM processes"
    ps -C beam.smp -o pid,ppid,pgid,stat,etime,args 2>/dev/null || echo "(none)"

    echo "== mix lock files"
    ls -la "${TMPDIR:-/tmp}/mix_lock_user$(id -u)" 2>/dev/null || echo "(none)"

    if [ "$GROUP" -eq 1 ]; then
      kill -KILL -- "-$PID" 2>/dev/null
    else
      pkill -KILL -P "$PID" 2>/dev/null
      kill -KILL "$PID" 2>/dev/null
    fi
    wait "$PID" 2>/dev/null
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done

wait "$PID"
