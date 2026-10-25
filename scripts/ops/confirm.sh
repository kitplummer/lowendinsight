#!/usr/bin/env bash
#
# Runs a production probe; if it fails, re-checks once after a pause, and
# fails only if the second run fails too.
#
#   scripts/ops/confirm.sh <name> <command> [args...]
#
# A failed GitHub run means the system is unhealthy. The monitor runs every 15
# minutes against production over the internet, and from 2026-10-10 to 10-24 it
# emailed for one empty homepage fetch, one SSL connect error and a canary
# false failure -- each gone by the next run. An alert that is sometimes noise
# stops being read.
#
# A real outage fails both runs and still fails this step, inside the same
# 15-minute window. The first failure is not hidden: it is a warning on the
# run, with its output above it.
#
# This is for probes, never tests. A test suite is deterministic and retrying
# it hides ordering bugs; that is forbidden here (CLAUDE.md, #107).
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <name> <command> [args...]" >&2; exit 2; }
NAME="$1"; shift
WAIT="${LEI_CONFIRM_WAIT:-60}"

# The first attempt's output is held and replayed with its errors as warnings:
# if the re-check passes, a red annotation on a green run says the opposite of
# what happened. The second attempt streams as it is.
FIRST_OUT=$("$@" 2>&1)
FIRST=$?
[ "$FIRST" -eq 0 ] && { printf '%s\n' "$FIRST_OUT"; exit 0; }
sed 's/^::error::/::warning::/' <<<"$FIRST_OUT"

echo "::warning::${NAME} failed once (exit ${FIRST}); re-checking in ${WAIT}s before calling production unhealthy."
sleep "$WAIT"

"$@" && { echo "::warning::${NAME} passed on re-check: the first failure was transient."; exit 0; }
SECOND=$?

echo "::error::${NAME} failed twice, ${WAIT}s apart (exit ${FIRST}, then ${SECOND}). This is not a blip."
exit "$SECOND"
