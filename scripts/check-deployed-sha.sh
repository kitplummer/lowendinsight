#!/usr/bin/env bash
#
# Does the running service report the commit we expect?
#
# Reads /metrics on stdin; takes the expected sha as $1.
#
# This exists because the deploy check could only ask GitHub which deploy runs
# it believed had succeeded. That is a check on the bookkeeping, not on the
# service: a deploy that reported success while shipping the wrong image, or a
# machine that quietly rolled back, both look deployed from the outside. On
# 2026-10-04 the tip of main sat undeployed for 79 minutes and the only reason
# anyone knew was that a deploy run had declined -- had it declined silently and
# reported success, nothing here would have noticed.
#
# Exits:
#   0  the running build is the expected commit
#   1  it is not, or we cannot tell -- which is not a reassuring answer
set -uo pipefail

EXPECTED="${1:-}"
if [ -z "$EXPECTED" ]; then
  echo "::error::check-deployed-sha.sh needs the expected sha as its first argument"
  exit 1
fi

METRICS="$(cat)"
LINE="$(printf '%s\n' "$METRICS" | grep -m1 '^lei_build_info{' || true)"

if [ -z "$LINE" ]; then
  # An old build publishes no such gauge. That is precisely the build whose
  # identity cannot be confirmed, so it is a failure rather than a skip.
  echo "::error::/metrics publishes no lei_build_info. The running build cannot be identified, so whether ${EXPECTED:0:7} is live is unknown."
  exit 1
fi

RUNNING="$(printf '%s\n' "$LINE" | sed -n 's/.*sha="\([^"]*\)".*/\1/p')"
VERSION="$(printf '%s\n' "$LINE" | sed -n 's/.*lei_version="\([^"]*\)".*/\1/p')"

if [ -z "$RUNNING" ] || [ "$RUNNING" = "unknown" ]; then
  echo "::error::The running build reports its commit as '${RUNNING:-empty}'. A build nobody can identify is the state you cannot verify; the deploy must pass --build-arg LEI_BUILD_SHA."
  exit 1
fi

echo "running ${RUNNING:0:7} (lowendinsight ${VERSION:-unknown}), expected ${EXPECTED:0:7}"

if [ "$RUNNING" != "$EXPECTED" ]; then
  echo "::error::The service reports ${RUNNING:0:7} but the tip of main is ${EXPECTED:0:7}. GitHub's deploy record and the running code disagree, and the service is the one to believe."
  exit 1
fi

echo "The running build is the tip of main."
