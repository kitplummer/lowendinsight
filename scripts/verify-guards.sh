#!/usr/bin/env bash
# Verify that guard tests actually catch the bugs they were written for.
#
# A passing test tells you it ran. It does not tell you it would catch
# anything. Every bug fixed in this repo recently shipped under green CI --
# the suites passed throughout, because they exercised the wrong layer.
#
# For each entry in scripts/mutations.json this reintroduces a bug that
# reached production, runs only the test written to catch it, and requires
# that test to FAIL. A guard that still passes under mutation is not a guard.
#
# The inverted conclusion is the point: the failure is consumed here, so a
# green run means "guards verified" rather than leaving an alarming red run
# in the branch list for someone to explain.
#
#   ./scripts/verify-guards.sh              # all mutations
#   ./scripts/verify-guards.sh acp-mount-prefix   # one, by id

set -uo pipefail

MANIFEST="$(dirname "$0")/../scripts/mutations.json"
ONLY="${1:-}"

green() { printf "\033[32m%s\033[0m\n" "$1"; }
red()   { printf "\033[31m%s\033[0m\n" "$1"; }
bold()  { printf "\033[1m%s\033[0m\n" "$1"; }

# Unconditional restore. A mutated working tree left behind is worse than a
# failed run: the next command in CI, or the next thing a developer does
# locally, operates on deliberately broken code.
BACKUP_DIR="$(mktemp -d)"
restore() {
  if [ -d "$BACKUP_DIR" ]; then
    while IFS= read -r -d '' saved; do
      rel="${saved#"$BACKUP_DIR"/}"
      cp "$saved" "$rel"
    done < <(find "$BACKUP_DIR" -type f -print0)
    rm -rf "$BACKUP_DIR"
  fi
}
trap restore EXIT INT TERM

backup_file() {
  local f="$1"
  mkdir -p "$BACKUP_DIR/$(dirname "$f")"
  cp "$f" "$BACKUP_DIR/$f"
}

PASS=0
FAIL=0
STALE=0

bold "=== Guard verification ==="
echo ""

IDS=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))['mutations']
print('\n'.join(x['id'] for x in m))
")

for id in $IDS; do
  if [ -n "$ONLY" ] && [ "$ONLY" != "$id" ]; then continue; fi

  eval "$(python3 -c "
import json, shlex
m = {x['id']: x for x in json.load(open('$MANIFEST'))['mutations']}['$id']
for k in ('file', 'guarded_by', 'app', 'bug'):
    print(f'{k.upper()}={shlex.quote(m[k])}')
")"

  bold "$id"
  echo "  guards against: $BUG"

  # Apply the mutation. A find string that no longer matches means the guarded
  # code changed -- report that distinctly from a guard failure, because the
  # two need different responses.
  backup_file "$FILE"

  if ! python3 -c "
import json, sys
m = {x['id']: x for x in json.load(open('$MANIFEST'))['mutations']}['$id']
src = open(m['file']).read()
n = src.count(m['find'])
if n != 1:
    sys.stderr.write(f'matched {n} times, expected exactly 1\n')
    sys.exit(1)
open(m['file'], 'w').write(src.replace(m['find'], m['replace'], 1))
" 2>/tmp/mut.err; then
    red "  STALE: the guarded code changed; 'find' no longer matches exactly once"
    sed 's/^/         /' /tmp/mut.err
    red "         Re-verify this guard still catches the bug, then update the manifest."
    STALE=$((STALE + 1))
    cp "$BACKUP_DIR/$FILE" "$FILE"
    echo ""
    continue
  fi

  # Run only the guarding test. It must fail.
  if (cd "$APP" && MIX_ENV=test mix test "$GUARDED_BY" >/tmp/guard.out 2>&1); then
    red "  FAIL: $GUARDED_BY still PASSED with the bug reintroduced."
    red "        This test does not actually guard against it."
    tail -5 /tmp/guard.out | sed 's/^/        /'
    FAIL=$((FAIL + 1))
  else
    green "  PASS: $GUARDED_BY caught the reintroduced bug"
    PASS=$((PASS + 1))
  fi

  cp "$BACKUP_DIR/$FILE" "$FILE"
  echo ""
done

restore

bold "=== $PASS verified, $FAIL unguarded, $STALE stale ==="

if [ "$FAIL" -gt 0 ] || [ "$STALE" -gt 0 ]; then
  exit 1
fi

green "All guards verified: every mutation was caught by its test."
