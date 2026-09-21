#!/usr/bin/env bash
#
# Did this commit actually deploy?
#
#   scripts/ops/deploy-status.sh [sha]      default: origin/main
#
# A deploy run concludes `success` when it deliberately ships nothing. The gate
# refuses to deploy a commit main has already moved past -- correctly, since
# deploying the older one would put production back a version -- and a workflow
# cannot choose its own conclusion, so declining and shipping look identical in
# the run list (#259).
#
# The answer is the `Deploy and verify` job's conclusion, together with the
# commit the run was about. This reads both. Read-only: it lists runs and jobs.
#
# Exit codes: 0 deployed, 1 not deployed, 2 could not tell. "Could not tell" is
# never reported as deployed -- that is the confusion this exists to end.
set -uo pipefail

REPO="${REPO:-kitplummer/lowendinsight}"
JOB="Deploy and verify"

die() { printf '%s\n' "$1" >&2; exit "${2:-2}"; }

command -v gh >/dev/null || die "gh is required but not installed"

if [ $# -ge 1 ]; then
  SHA="$1"
else
  SHA=$(git rev-parse origin/main 2>/dev/null) ||
    die "no sha given and origin/main could not be read"
fi

# A short sha is a fine thing to be handed; runs carry the full one.
if [ ${#SHA} -lt 40 ]; then
  FULL=$(git rev-parse "$SHA" 2>/dev/null) || die "could not expand '$SHA' to a full sha"
  SHA="$FULL"
fi

printf 'commit   %s\n' "${SHA:0:7}"

CI=$(gh run list --repo "$REPO" --workflow umbrella_ci --limit 30 \
  --json headSha,status,conclusion \
  --jq ".[] | select(.headSha==\"$SHA\") | \"\(.status) \(.conclusion // \"-\")\"" 2>/dev/null | head -1)

printf 'umbrella_ci  %s\n' "${CI:-no run found}"

RUNS=$(gh run list --repo "$REPO" --workflow deploy --limit 30 \
  --json databaseId,headSha --jq ".[] | select(.headSha==\"$SHA\") | .databaseId" 2>/dev/null)

if [ -z "$RUNS" ]; then
  printf 'deploy       no run for this commit\n'
  case "$CI" in
    "completed success"*) die "NOT DEPLOYED: CI passed but no deploy run exists for it." 1 ;;
    *) die "NOT DEPLOYED: CI has not finished successfully, so no deploy was triggered." 1 ;;
  esac
fi

STATUS=1
for RUN in $RUNS; do
  CONCLUSION=$(gh run view "$RUN" --repo "$REPO" --json jobs \
    --jq ".jobs[] | select(.name==\"$JOB\") | .conclusion" 2>/dev/null)

  RUN_CONCLUSION=$(gh run view "$RUN" --repo "$REPO" --json conclusion --jq '.conclusion' 2>/dev/null)

  case "${CONCLUSION:-missing}" in
    success)
      printf 'deploy %s  job=success   run=%s\n' "$RUN" "${RUN_CONCLUSION:-?}"
      printf '\nDEPLOYED: %s is live (run %s).\n' "${SHA:0:7}" "$RUN"
      exit 0
      ;;
    skipped)
      # The gate declined: main had moved past this commit by the time CI
      # finished. The run still concludes success.
      printf 'deploy %s  job=skipped   run=%s  (declined, shipped nothing)\n' \
        "$RUN" "${RUN_CONCLUSION:-?}"
      ;;
    failure | cancelled)
      printf 'deploy %s  job=%s   run=%s\n' "$RUN" "$CONCLUSION" "${RUN_CONCLUSION:-?}"
      ;;
    missing)
      printf 'deploy %s  job not found; the run may still be starting\n' "$RUN"
      STATUS=2
      ;;
    *)
      printf 'deploy %s  job=%s\n' "$RUN" "$CONCLUSION"
      STATUS=2
      ;;
  esac
done

printf '\n'
if [ "$STATUS" = "2" ]; then
  die "COULD NOT TELL: a deploy run exists but its job state is unreadable." 2
fi

die "NOT DEPLOYED: every deploy run for this commit declined or failed." 1
