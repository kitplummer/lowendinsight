#!/usr/bin/env bash
# Does the report cache have room, and will it fail the way we chose?
#
# The corpus lives in Redis, so memory is the ceiling on the corpus. Under a
# volatile eviction policy that ceiling arrives as entries being dropped: the
# evicted customer's next request is a cache miss indistinguishable from any
# other miss, and the job that filled memory succeeds. There is nothing to
# notice, which is why this is watched rather than waited for (ADR-008).
#
# Reads /metrics on stdin, so it can be tested by execution rather than by
# grepping the workflow that calls it. A check asserted by looking for strings
# in YAML cannot catch a change to the logic -- which is how this script came to
# exist, after two mutations against the inline version came back unguarded.
#
#   ./scripts/check-cache-headroom.sh < metrics.txt
#
# Environment: WARN_PCT (80), EXPECTED_POLICY (optimistic-volatile).
# Exit 0 when there is headroom and the policy is the expected one, 1 otherwise.

set -uo pipefail

WARN_PCT="${WARN_PCT:-80}"
EXPECTED_POLICY="${EXPECTED_POLICY:-optimistic-volatile}"

METRICS=$(cat)
FAILED=0

gauge() { echo "$METRICS" | sed -n "$1" | head -1; }

READABLE=$(gauge 's/^lei_redis_memory_readable \([01]\)$/\1/p')

if [ "$READABLE" != "1" ]; then
  echo "::error::Redis memory is not readable (lei_redis_memory_readable=${READABLE:-absent}), so the cache's headroom cannot be checked. Either the deployed release predates the metric, or Redis is not answering INFO."
  exit 1
fi

USED=$(gauge 's/^lei_redis_memory_bytes{type="used"} \([0-9]*\)$/\1/p')
MAX=$(gauge 's/^lei_redis_maxmemory_bytes \([0-9]*\)$/\1/p')

if [ -z "$USED" ] || [ -z "$MAX" ]; then
  echo "::error::Redis reports itself readable but the byte gauges could not be parsed."
  FAILED=1
elif [ "$MAX" = "0" ]; then
  # 0 is Redis's own way of saying unlimited. There is then no ceiling to
  # measure against, and "no ceiling" is not headroom: unbounded growth ends at
  # the machine rather than at a policy. The operations notes claimed exactly
  # this configuration, so it is the state this is most likely to meet.
  echo "::error::maxmemory is 0 (unlimited), so there is no budget to measure headroom against. Set one, or answer ADR-008 question 1."
  FAILED=1
else
  PCT=$(( USED * 100 / MAX ))
  echo "cache memory: ${USED} of ${MAX} bytes (${PCT}%), warn at ${WARN_PCT}%"

  if [ "$PCT" -ge "$WARN_PCT" ]; then
    echo "::error::The cache is at ${PCT}% of its ${MAX}-byte budget. Under a volatile eviction policy the next thing that happens is other customers' reports being dropped, silently."
    FAILED=1
  fi
fi

POLICY=$(gauge 's/^lei_redis_maxmemory_policy{policy="\([^"]*\)"} 1$/\1/p')
echo "eviction policy: ${POLICY:-unreadable}  expected: ${EXPECTED_POLICY}"

if [ -z "$POLICY" ]; then
  echo "::error::No eviction policy gauge, so which failure happens at the ceiling cannot be read."
  FAILED=1
elif [ "$POLICY" != "$EXPECTED_POLICY" ]; then
  # Which policy is in force decides *which* failure happens at the ceiling.
  # It arrived once already as a provider default; it must not change silently
  # a second time.
  echo "::error::Eviction policy is '${POLICY}', expected '${EXPECTED_POLICY}'. That changes what happens when the cache fills -- dropping other customers' entries versus refusing writes -- which is a decision rather than a setting. Update LEI_REDIS_EXPECTED_POLICY if it was deliberate."
  FAILED=1
fi

exit "$FAILED"
