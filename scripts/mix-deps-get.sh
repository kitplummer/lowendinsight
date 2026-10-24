#!/usr/bin/env bash
#
# `mix deps.get`, retried when it fails.
#
#   scripts/mix-deps-get.sh [mix deps.get args]
#
# On 2026-10-24 hex.pm answered one request with 500 Internal Server Error
# ("Failed to fetch record for jose from registry") during umbrella_ci on main.
# One job failed, so the run failed; deploy rightly declined a commit whose CI
# had failed; and monitor then reported "the tip of main is not deployed" every
# fifteen minutes for seven hours -- for a change to one line of the CHANGELOG.
#
# A registry outage is not a defect in this code, so retrying the fetch hides
# nothing. That is the line this repository draws: tests are never retried
# (a retry over a randomised suite turns ordering bugs into passes), and this
# retries no tests. Each failed attempt is a visible warning; a fetch that
# fails every time still fails the job.
set -uo pipefail

ATTEMPTS=3
DELAY="${LEI_DEPS_RETRY_DELAY:-15}"

for attempt in $(seq 1 "$ATTEMPTS"); do
  if mix deps.get "$@"; then
    exit 0
  fi

  if [ "$attempt" -lt "$ATTEMPTS" ]; then
    wait=$((DELAY * attempt))
    echo "::warning::mix deps.get failed (attempt ${attempt} of ${ATTEMPTS}); retrying in ${wait}s"
    sleep "$wait"
  fi
done

echo "::error::mix deps.get failed ${ATTEMPTS} times. If the output above is a registry error, hex.pm may be down: https://status.hex.pm"
exit 1
