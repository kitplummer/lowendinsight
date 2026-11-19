#!/usr/bin/env bash
#
# Runs a script as it is in the commit production is running, not as it is
# in this checkout.
#
#   scripts/ops/run-deployed.sh <base-url> <script> [args...]
#
# The monitor checks out main and probes production every 15 minutes. Between
# a merge and its deploy, main's smoke test describes a release that is not
# running yet, so any change to what the smoke test expects failed the monitor
# for the length of every deploy, against a production that was fine. The MCP
# change that opened tools/list to callers without a key could not ship its
# own smoke check for that reason.
#
# The commit comes from /metrics (lei_build_info), read fresh each time: under
# scripts/ops/confirm.sh, a re-check after a deploy finishes uses the new one.
# A build that cannot name its commit fails here. Falling back to this
# checkout's copy would bring the false failures back, and the deploy check
# already fails on such a build.
set -uo pipefail

[ $# -ge 2 ] || { echo "usage: $0 <base-url> <script> [args...]" >&2; exit 2; }
BASE_URL="$1"
SCRIPT="$2"
shift 2

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

"$(dirname "$0")/fetch-metrics.sh" "$BASE_URL" "$WORK/metrics.txt" || exit 1

SHA=$(sed -n 's/^lei_build_info{.*sha="\([^"]*\)".*/\1/p' "$WORK/metrics.txt" | head -1)

if [ -z "$SHA" ] || [ "$SHA" = "unknown" ]; then
  echo "::error::Production does not name the commit it is running (lei_build_info sha '${SHA:-absent}'), so which ${SCRIPT} describes it is unknown. Nothing was run."
  exit 1
fi

# actions/checkout fetches only the tip of main; during a deploy the running
# commit is behind it.
if ! git cat-file -e "${SHA}^{commit}" 2>/dev/null; then
  if ! git fetch -q --depth=1 origin "$SHA"; then
    echo "::error::Production runs ${SHA:0:7}, which could not be fetched, so its ${SCRIPT} cannot be run. Nothing was run."
    exit 1
  fi
fi

mkdir "$WORK/tree"
if ! git archive "$SHA" | tar -x -C "$WORK/tree"; then
  echo "::error::Could not read ${SHA:0:7}'s tree. Nothing was run."
  exit 1
fi

if [ ! -f "$WORK/tree/$SCRIPT" ]; then
  echo "::error::${SHA:0:7}, the running commit, has no ${SCRIPT}. Nothing was run."
  exit 1
fi

echo "Running ${SCRIPT} as of ${SHA:0:7}, the commit production is running (this checkout is $(git rev-parse --short HEAD))."
cd "$WORK/tree" && bash "./$SCRIPT" "$@"
