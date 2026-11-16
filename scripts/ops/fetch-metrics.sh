#!/usr/bin/env bash
#
# Fetches production's /metrics once, for every monitor check to read.
#
#   scripts/ops/fetch-metrics.sh <base-url> <out-file>
#
# The monitor runs this under scripts/ops/confirm.sh. Until 2026-11-02 seven
# checks each fetched /metrics themselves, unconfirmed, and one request timing
# out failed the run with nothing but "exit code 28": `METRICS=$(curl ...)`
# under `bash -e` dies before any message. The next run was green.
#
# A failed fetch removes <out-file> rather than leave an older copy to be read
# as current, and a response that is empty or is not lei's metrics fails here:
# downstream, a missing gauge reads as "this release predates it", which is a
# warning, not an error.
set -uo pipefail

[ $# -eq 2 ] || { echo "usage: $0 <base-url> <out-file>" >&2; exit 2; }
URL="${1%/}/metrics"
OUT="$2"

rm -f "$OUT"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

curl -sS --fail --max-time 15 "$URL" > "$TMP"
CODE=$?

if [ "$CODE" -ne 0 ]; then
  echo "::error::${URL} did not answer (curl exit ${CODE}; 28 is a timeout, 22 an error status). No check that reads it can run."
  exit 1
fi

if ! grep -q '^lei_' "$TMP"; then
  echo "::error::${URL} answered, but not with lei's metrics ($(wc -c < "$TMP") bytes, no lei_ gauge). No check that reads it can run."
  head -c 300 "$TMP"
  exit 1
fi

mv "$TMP" "$OUT"
echo "Read ${URL}: $(grep -c '^lei_' "$OUT") lei_ samples."
