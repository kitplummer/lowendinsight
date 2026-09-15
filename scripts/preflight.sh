#!/usr/bin/env bash
#
# The definition of done. Run before opening or updating a pull request.
#
#   scripts/preflight.sh            # everything
#   scripts/preflight.sh --quick    # skip the seed sweep and grant check
#
# CI runs the same script. That is the point: when local and CI disagree about
# what "passing" means, the weaker one wins by default and nobody notices. Every
# defect this repo has shipped recently was green somewhere at the time.
#
# Each stage answers a different question:
#
#   compile          does it build without new warnings
#   suite            does the code do what the tests say
#   seed sweep       does it still, in a different order
#   guards           would the tests catch the bug coming back
#   backup grants    can the backup role still dump what migrations create
#
# A stage that cannot run is a failure, not a skip. Reporting success for work
# not done is the specific fault this script exists to prevent.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

SEEDS="${PREFLIGHT_SEEDS:-3}"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }
red()   { printf '\033[31m%s\033[0m\n' "$1"; }
dim()   { printf '\033[2m%s\033[0m\n' "$1"; }

FAILED=()
PASSED=()
SKIPPED=()

stage() {
  local name="$1"; shift
  bold "── $name"

  if "$@"; then
    green "   ok"
    PASSED+=("$name")
  else
    red "   FAILED"
    FAILED+=("$name")
  fi
  echo
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    red "$1 is not on PATH."
    red "Install the toolchain with: mise install   (see CLAUDE.md)"
    exit 1
  }
}

need mix
need psql

# Refuse to run alongside another mix invocation on this project.
#
# Two mix commands in the same umbrella contend on the build lock and the test
# databases. Backgrounding preflight while running mix test in another shell
# produced a suite failure and a run that emitted no summary at all -- both
# self-inflicted, and both indistinguishable from a real order-dependent bug
# until half an hour had gone into chasing one.
#
# A result you have to interpret is worse than no result.
#
# Matches the BEAM process that actually holds the lock, not any shell whose
# command line happens to contain the words. A looser pattern matched this
# script's own wrapper and would have fired every time -- a check that always
# fires is as useless as one that never does.
OTHERS=$(pgrep -af "beam\.smp.*bin/mix (test|compile|run|ecto)" 2>/dev/null || true)

if [ -n "$OTHERS" ]; then
  red "Another mix process is running against this project:"
  sed 's/^/    /' <<<"$OTHERS"
  echo
  red "Preflight shares a build lock and test databases with it, so the result"
  red "would not mean anything. Wait for it to finish, or stop it."
  exit 1
fi

# --- stages ---------------------------------------------------------------

check_format() {
  mix format --check-formatted 2>&1 | tail -20
  return "${PIPESTATUS[0]}"
}

check_compile() {
  # Warnings as errors. A warning is the compiler noticing something you did
  # not mean; letting them accumulate means the one that matters is invisible.
  mix compile --force --warnings-as-errors 2>&1 | grep -vE "^\s*$" | tail -30
  return "${PIPESTATUS[0]}"
}

check_databases() {
  # The service owns both Repos (ADR-003: the library has no database), and
  # both need their test database to exist. Without this the suite stage fails
  # on a migration error that looks like a code fault and is not one -- which
  # is its own kind of false signal.
  local failed=0
  for app in apps/lei_service; do
    dim "   $app"
    (cd "$app" && MIX_ENV=test mix ecto.create --quiet && MIX_ENV=test mix ecto.migrate >/dev/null) || failed=1
  done
  return $failed
}

check_suite() {
  local failed=0
  for app in apps/lowendinsight apps/lei_service; do
    dim "   $app"
    (cd "$app" && MIX_ENV=test mix test --exclude network --exclude long) || failed=1
  done
  return $failed
}

check_seed_sweep() {
  # Application env, ETS and the working directory all outlive the test that
  # touched them. A single ordering finds that eventually; several find it now.
  local failed=""
  for _ in $(seq 1 "$SEEDS"); do
    local seed=$((RANDOM * RANDOM % 999983 + 1))
    dim "   seed $seed"
    (cd apps/lowendinsight && MIX_ENV=test mix test --seed "$seed" --exclude network --exclude long >/dev/null 2>&1) \
      || failed="$failed $seed"
  done

  if [ -n "$failed" ]; then
    red "   order-dependent failure on seed(s):$failed"
    red "   reproduce: cd apps/lowendinsight && mix test --seed <seed>"
    return 1
  fi
}

check_guards() {
  ./scripts/verify-guards.sh >/tmp/preflight-guards.out 2>&1 || {
    tail -25 /tmp/preflight-guards.out
    return 1
  }
  tail -2 /tmp/preflight-guards.out
}

check_backup_grants() {
  ./scripts/verify-backup-grants.sh >/tmp/preflight-grants.out 2>&1 || {
    tail -25 /tmp/preflight-grants.out
    return 1
  }
  grep -c PASS /tmp/preflight-grants.out >/dev/null && dim "   grants verified"
}

# --- run ------------------------------------------------------------------

bold "=== preflight ==="
echo

stage "format"   check_format
stage "compile"  check_compile
stage "databases" check_databases
stage "suite"    check_suite
stage "guards"   check_guards

if [ "$QUICK" -eq 1 ]; then
  SKIPPED+=("seed sweep" "backup grants")
  dim "── seed sweep, backup grants: skipped (--quick)"
  echo
else
  stage "seed sweep ($SEEDS seeds)" check_seed_sweep
  stage "backup grants"             check_backup_grants
fi

# --- report ---------------------------------------------------------------

bold "=== preflight summary ==="
for s in "${PASSED[@]:-}";  do [ -n "$s" ] && green "  ok      $s"; done
for s in "${SKIPPED[@]:-}"; do [ -n "$s" ] && dim   "  skipped $s"; done
for s in "${FAILED[@]:-}";  do [ -n "$s" ] && red   "  FAILED  $s"; done
echo

if [ "${#FAILED[@]}" -gt 0 ]; then
  red "Preflight failed. Do not open the PR yet."
  exit 1
fi

if [ "${#PASSED[@]}" -eq 0 ]; then
  # Same failure this script exists to prevent: nothing ran, nothing failed.
  red "No stages ran. That is a failure, not a clean run."
  exit 1
fi

green "Preflight passed."

if [ "$QUICK" -eq 1 ]; then
  echo
  dim "Run without --quick before opening the PR. The skipped stages are the"
  dim "ones that catch ordering bugs and migration/grant drift -- the two"
  dim "classes that have reached production here."
fi
