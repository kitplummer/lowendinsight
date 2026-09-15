#!/usr/bin/env bash
#
# Proves the lowendinsight library stands alone (ADR-003).
#
#   scripts/library-isolation.sh
#
# Inside the umbrella every app shares one deps directory, so the library can
# compile against a dependency only the service declares and nothing notices:
# it called Jason for months without depending on it. This builds a fresh
# project outside the umbrella whose only dependency is the library, then:
#
#   1. the resolved dependencies include nothing that belongs to the service
#   2. it compiles, and the library itself compiles without warnings
#   3. the library starts with no configuration, loading no service code
#   4. with scoring thresholds configured, it analyzes a real git repository,
#      and the report's config holds only those thresholds
#   5. the Hex package declares no service dependency
#
# Every check must positively pass; a step that cannot run is a failure.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/apps/lowendinsight"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FORBIDDEN="ecto ecto_sql postgrex plug plug_cowboy cowboy joken exqlite oban redix"

pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; exit 1; }

cd "$WORK" || fail "work directory"
MIX_QUIET=1 mix new consumer >/dev/null 2>&1 || fail "mix new"
cd consumer || fail "consumer project"

python3 - "$LIB" <<'EOF' || fail "write consumer mix.exs"
import sys
lib = sys.argv[1]
p = "mix.exs"
s = open(p).read()
marker = '      # {:dep_from_hexpm, "~> 0.3.0"},'
assert marker in s, "mix new template changed"
open(p, "w").write(s.replace(marker, f'      {{:lowendinsight, path: "{lib}"}},'))
EOF

mix deps.get >deps.log 2>&1 || fail "deps.get" "$(tail -5 deps.log)"

# 1. Dependencies
RESOLVED=$(mix deps 2>/dev/null | sed -n 's/^\* \([a-z_0-9]*\).*/\1/p' | sort -u)
[ -n "$RESOLVED" ] && echo "$RESOLVED" | grep -qx lowendinsight || fail "dependencies resolved" "mix deps listed no lowendinsight"
for dep in $FORBIDDEN; do
  if echo "$RESOLVED" | grep -qx "$dep"; then
    fail "no service dependencies" "$dep is resolved for a project that depends only on the library"
  fi
done
pass "no service dependencies ($(echo "$RESOLVED" | wc -l | tr -d ' ') resolved)"

# 2. Compiles, and the library itself compiles cleanly. Third-party
# dependencies warn on this toolchain (elixir_uuid, yaml_elixir), so compile
# them first and judge only the library's own recompilation.
mix deps.compile >deps-compile.log 2>&1 || fail "dependencies compile" "$(tail -5 deps-compile.log)"
mix deps.compile lowendinsight --force >lib-compile.log 2>&1 || fail "library compiles" "$(tail -5 lib-compile.log)"
grep -q "==> lowendinsight" lib-compile.log || fail "library compiles" "no lowendinsight compilation in the log; checked nothing"
if grep -q "warning:" lib-compile.log; then
  fail "library compiles without warnings" "$(grep -A3 'warning:' lib-compile.log | head -8)"
fi
mix compile >compile.log 2>&1 || fail "consumer compiles" "$(tail -5 compile.log)"
pass "compiles; library compiles without warnings"

# 3. Starts with no configuration, and no service code is present
BOOT=$(mix run -e '
  {:ok, _} = Application.ensure_all_started(:lowendinsight)
  present = Enum.filter([Lei.Repo, Lei.Stripe, Lei.Web.Router, LeiService.Endpoint, Ecto.Repo, Plug.Conn], &Code.ensure_loaded?/1)
  IO.puts("PRESENT=" <> inspect(present))
' 2>&1) || fail "starts with no configuration" "$(echo "$BOOT" | tail -5)"
echo "$BOOT" | grep -q '^PRESENT=\[\]$' || fail "no service code loaded" "$(echo "$BOOT" | grep PRESENT= || echo "$BOOT" | tail -3)"
pass "starts with no configuration; no service modules present"

# 4. Analyzes a real repository with thresholds configured
REPO="$WORK/sample-repo"
mkdir -p "$REPO" && (cd "$REPO" && git init -q && git config user.email t@example.com \
  && git config user.name Tester && echo hello > README.md && git add . && git commit -qm init) \
  || fail "sample git repository"

mkdir -p config && cat > config/config.exs <<'EOF'
import Config

config :lowendinsight,
  sbom_risk_level: "medium",
  critical_contributor_level: 2,
  high_contributor_level: 3,
  medium_contributor_level: 5,
  critical_currency_level: 104,
  high_currency_level: 52,
  medium_currency_level: 26,
  critical_large_commit_level: 0.30,
  high_large_commit_level: 0.15,
  medium_large_commit_level: 0.05,
  critical_functional_contributors_level: 2,
  high_functional_contributors_level: 3,
  medium_functional_contributors_level: 5,
  critical_agentic_level: 0.9,
  high_agentic_level: 0.7,
  medium_agentic_level: 0.3,
  jobs_per_core_max: 1,
  base_temp_dir: System.tmp_dir!()
EOF

ANALYSIS=$(mix run -e "
  {:ok, r} = AnalyzerModule.analyze(\"file://$REPO\", \"isolation\", %{types: false})
  IO.puts(\"RISK=\" <> to_string(r[:data][:risk]))
  keys = r[:data][:config] |> Map.keys() |> Enum.map(&to_string/1)
  IO.puts(\"CONFIG_KEYS=\" <> Integer.to_string(length(keys)))
  IO.puts(\"CONFIG_ONLY_THRESHOLDS=\" <> to_string(keys != [] and Enum.all?(keys, &String.ends_with?(&1, \"_level\"))))
" 2>&1) || fail "analysis runs" "$(echo "$ANALYSIS" | tail -5)"

echo "$ANALYSIS" | grep -qE '^RISK=(critical|high|medium|low)$' || fail "analysis produces a risk level" "$(echo "$ANALYSIS" | tail -3)"
echo "$ANALYSIS" | grep -q '^CONFIG_ONLY_THRESHOLDS=true$' || fail "report config is only thresholds" "$(echo "$ANALYSIS" | grep CONFIG_)"
pass "analyzes a git repository: $(echo "$ANALYSIS" | sed -n 's/^RISK=//p') risk, report config only thresholds"

# 5. The Hex package declares no service dependency
HEX=$(cd "$LIB" && mix hex.build 2>&1) || fail "hex.build" "$(echo "$HEX" | tail -5)"
rm -f "$LIB"/lowendinsight-*.tar
DECLARED=$(echo "$HEX" | sed -n '/^  Dependencies:/,/^  [A-Z]/p' | sed -n 's/^    \([a-z_0-9]*\) .*/\1/p')
[ -n "$DECLARED" ] || fail "hex.build lists dependencies" "could not read the Dependencies section"
for dep in $FORBIDDEN; do
  if echo "$DECLARED" | grep -qx "$dep"; then
    fail "Hex package declares no service dependency" "$dep"
  fi
done
pass "Hex package declares no service dependency ($(echo "$DECLARED" | tr '\n' ' '))"

echo
echo "The library stands alone."
