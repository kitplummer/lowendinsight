#!/usr/bin/env bash
#
# Does the published library agree with the tree? Run by audit.yml, daily and
# on every pull request, from the repository root.
#
#   GITHUB_EVENT_NAME   schedule | workflow_dispatch | pull_request
#   LEI_DRIFT_BASE      what a pull request is compared against (origin/main)
#   LEI_DATED_GRACE_HOURS  how long a dated version may wait for its tag (72)
#
# It fails only when a release has actually gone wrong, because a failed run
# emails and an email has to mean something is unhealthy. Until 2026-10-24 it
# went red for every release between dating the CHANGELOG and pushing the tag,
# and on main for a library change merged before anyone bumped the version --
# while passing whenever hex could not be read.
#
#   * the tree's version is already published and a change to the library
#     moves past its tag: the next release has no number, which is the state in
#     which commits accumulate unnoticed. Fails the pull request that does it,
#     so main does not; and the daily run, in case one got in anyway.
#   * the CHANGELOG gives the tree's version a ship date and hex does not have
#     it. 0.14.0 and 0.15.0 were dated 2026-10-05 and never tagged, and nothing
#     said so for three weeks. A warning while the release is in progress; a
#     failure once the date is older than the grace period.
#   * hex has a version the CHANGELOG still calls unreleased.
#
# Covered by test/lei_service/release_drift_test.exs.
set -uo pipefail

EVENT="${GITHUB_EVENT_NAME:-schedule}"
BASE="${LEI_DRIFT_BASE:-origin/main}"
GRACE_HOURS="${LEI_DATED_GRACE_HOURS:-72}"
MIX=apps/lowendinsight/mix.exs
CHANGELOG=apps/lowendinsight/CHANGELOG.md

FAILED=0
fail() { echo "::error::$1"; FAILED=1; }
# Errors that a pull request cannot have caused report on the pull request and
# fail the daily run.
fail_daily() {
  if [ "$EVENT" = "pull_request" ]; then
    echo "::warning::$1 (reported here; the daily run fails on this)"
  else
    fail "$1"
  fi
}

VERSION=$(sed -n 's/.*version: "\([^"]*\)".*/\1/p' "$MIX" | head -1)
PUBLISHED=$(curl -sf --retry 4 --retry-all-errors --retry-delay 15 --max-time 30 \
  https://hex.pm/api/packages/lowendinsight | jq -r '.releases[].version' 2>/dev/null) || PUBLISHED=""
HEX=$(head -1 <<<"$PUBLISHED")

if [ -z "$HEX" ]; then
  fail_daily "Could not read lowendinsight's published versions from hex.pm after retrying for about a minute. Whether the release and the tree agree is unknown."
  exit "$FAILED"
fi

echo "tree: $VERSION   hex (newest): $HEX"

# The tree's version is already out, and the library has moved past its tag.
if grep -qxF "$VERSION" <<<"$PUBLISHED"; then
  if [ "$EVENT" = "pull_request" ]; then
    MOVED=$(git diff --name-only "${BASE}...HEAD" -- apps/lowendinsight | wc -l | tr -d ' ')
  else
    MOVED=$(git log "v${VERSION}..HEAD" --oneline -- apps/lowendinsight | wc -l | tr -d ' ')
  fi

  if [ "$MOVED" != "0" ]; then
    fail "This changes the library after v${VERSION}, which is already published on hex. Bump the version in ${MIX} and add an Unreleased section to the CHANGELOG in the same change, or it ships to nobody."
  fi
fi

# The tree's version carries a ship date that hex does not bear out.
HEADING=$(grep -m1 -F "## ${VERSION} " "$CHANGELOG" || true)
if [[ "$HEADING" =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]] && ! grep -qxF "$VERSION" <<<"$PUBLISHED"; then
  # When the heading took its current form, not the date written in it: that
  # is a plan, this is when it was merged.
  DATED_AT=$(git log -1 --format=%ct -S"$HEADING" -- "$CHANGELOG")
  AGE_HOURS=$(( ( $(date +%s) - ${DATED_AT:-0} ) / 3600 ))

  if [ "$AGE_HOURS" -gt "$GRACE_HOURS" ]; then
    fail_daily "The CHANGELOG has called ${VERSION} shipped for ${AGE_HOURS} hours ('${HEADING}'), but hex has no ${VERSION}. Push the tag v${VERSION} -- or, if the release workflow failed, fix it -- or put the section back to Unreleased."
  else
    echo "::warning::${VERSION} is dated in the CHANGELOG but not yet on hex (${AGE_HOURS}h). Push the tag v${VERSION}; this fails after ${GRACE_HOURS}h."
  fi
fi

# A published version whose section still says unreleased.
if grep -qiE "^## +${HEX//./\\.} .*unreleased" "$CHANGELOG"; then
  fail_daily "CHANGELOG calls ${HEX} unreleased, but it is published on hex. Give it the date it shipped."
fi

exit "$FAILED"
