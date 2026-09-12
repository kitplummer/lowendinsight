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

# Validate the manifest before doing anything with it.
#
# This block exists because the script failed exactly the way it was built to
# catch. With an unparseable manifest, IDS came back empty, the loop ran zero
# times, and it printed "0 verified, 0 unguarded" and exited 0 -- a green run
# reporting that every guard was verified, having verified nothing. A malformed
# JSON file is far more likely than it sounds: the manifest is appended to by
# almost every branch and is a recurring merge-conflict site.
if ! python3 - "$MANIFEST" <<'VALIDATE'
import json, os, sys

path = sys.argv[1]
# 'replace' is deliberately absent: an empty replace is a deletion mutation,
# which is how several guards reintroduce a bug that was fixed by adding a
# line. It is checked separately for being a string that differs from 'find'.
required = ("id", "bug", "file", "find", "guarded_by", "app")
problems = []

try:
    with open(path) as f:
        manifest = json.load(f)
except FileNotFoundError:
    sys.exit(f"manifest not found: {path}")
except json.JSONDecodeError as e:
    sys.exit(f"manifest is not valid JSON: {e}")

mutations = manifest.get("mutations")

if not isinstance(mutations, list):
    sys.exit("manifest has no 'mutations' list")

# The check that matters most. An empty list is not "nothing to do", it is a
# manifest that has lost its contents.
if not mutations:
    sys.exit("manifest contains no mutations — refusing to report success")

seen = set()

for i, m in enumerate(mutations):
    where = m.get("id") or f"entry {i}"

    if not isinstance(m, dict):
        problems.append(f"{where}: not an object")
        continue

    for key in required:
        if not m.get(key):
            problems.append(f"{where}: missing or empty '{key}'")

    if m.get("id") in seen:
        # Duplicate ids silently shadow each other in the lookup below, so one
        # mutation would never run while still being counted as present.
        problems.append(f"{where}: duplicate id")
    seen.add(m.get("id"))

    if not isinstance(m.get("replace"), str):
        problems.append(f"{where}: 'replace' must be a string (\"\" to delete)")
    elif m.get("find") == m.get("replace"):
        problems.append(f"{where}: 'find' and 'replace' are identical — mutates nothing")

    target = m.get("file")
    if target and not os.path.isfile(target):
        problems.append(f"{where}: file does not exist: {target}")

    app, guarded_by = m.get("app"), m.get("guarded_by")
    if app and guarded_by and not os.path.isfile(os.path.join(app, guarded_by)):
        problems.append(f"{where}: guarding test does not exist: {app}/{guarded_by}")

if problems:
    sys.exit("manifest is invalid:\n  " + "\n  ".join(problems))

print(f"{len(mutations)} mutations declared", file=sys.stderr)
VALIDATE
then
  red "Manifest validation failed. Not running -- a manifest that cannot be read"
  red "would otherwise produce a green run that checked nothing."
  exit 1
fi

IDS=$(python3 -c "
import json
m = json.load(open('$MANIFEST'))['mutations']
print('\n'.join(x['id'] for x in m))
")

if [ -z "$IDS" ]; then
  red "No mutation ids read from the manifest. Refusing to report success."
  exit 1
fi

if [ -n "$ONLY" ] && ! grep -qx "$ONLY" <<<"$IDS"; then
  # Previously a typo here skipped every mutation and exited 0.
  red "No mutation with id '$ONLY'. Known ids:"
  sed 's/^/  /' <<<"$IDS"
  exit 1
fi

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

# Belt and braces against the same failure arriving by another route: if
# nothing ran, this is not a pass.
if [ "$PASS" -eq 0 ]; then
  red "No mutations were verified. That is a failure, not a clean run."
  exit 1
fi

green "All guards verified: every mutation was caught by its test."
