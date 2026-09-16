#!/usr/bin/env bash
# Show, or discard, the analysis jobs left `executing` before Lifeline existed.
#
#   scripts/ops/orphaned-jobs.sh                   show them (read-only)
#   scripts/ops/orphaned-jobs.sh discard-trending  discard the trending batches
#
# Production had no Oban Lifeline, so jobs running when a deploy stopped the
# node stayed `executing` forever. Once Lifeline is deployed it re-queues every
# such job. The single-repository jobs are requests someone made, so Lifeline
# should re-run them. The multi-repository jobs are midnight trending batches
# (from before #158 took trending off the queue): nobody is waiting on them,
# today's trending reports replaced them, and re-running them brings back the
# clone pile-up #158 fixed. Run discard-trending BEFORE deploying Lifeline.
#
# Prints counts and times only -- never the repository URLs (#149).
set -euo pipefail

APP="${APP:-lowendinsight}"
# discard-trending refuses to change anything unless exactly this many match.
EXPECT="${EXPECT:-60}"
CUTOFF="2026-09-14 12:00:00"

show='%{rows: rows} = Ecto.Adapters.SQL.query!(LeiService.Repo, "SELECT CASE WHEN jsonb_array_length(args->$1) > 1 THEN $2 ELSE $3 END, count(*), min(attempted_at)::text, max(attempted_at)::text FROM oban_jobs WHERE state = $4 GROUP BY 1 ORDER BY 1", ["urls", "trending batch (discard)", "single request (Lifeline re-runs)", "executing"])
IO.puts("executing jobs:")
if rows == [], do: IO.puts("  none")
for [kind, n, from, to] <- rows, do: IO.puts("  #{kind}: #{n}  (#{from} .. #{to})")'

case "${1:-show}" in
  show) code="$show" ;;
  discard-trending)
    [[ "$EXPECT" =~ ^[0-9]+$ ]] || { echo "EXPECT must be a number" >&2; exit 2; }
    code="LeiService.Repo.transaction(fn ->
  %{num_rows: n} = Ecto.Adapters.SQL.query!(LeiService.Repo, \"UPDATE oban_jobs SET state = 'discarded', discarded_at = now(), errors = array_append(errors, jsonb_build_object('at', now(), 'attempt', attempt, 'error', 'discarded by scripts/ops/orphaned-jobs.sh: trending batch orphaned before Lifeline; superseded by the synchronous trending refresh (#158)')) WHERE state = 'executing' AND jsonb_array_length(args->'urls') > 1 AND attempted_at < '${CUTOFF}'\", [])
  if n == ${EXPECT} do
    IO.puts(\"discarded #{n} trending batch jobs\")
  else
    IO.puts(\"matched #{n}, expected ${EXPECT}: nothing changed\")
    LeiService.Repo.rollback(:unexpected_count)
  end
end)
${show}"
    ;;
  *) echo "usage: $0 [show | discard-trending]" >&2; exit 2 ;;
esac

# Base64 so the Elixir survives ssh and shell quoting untouched.
b64=$(printf '%s' "$code" | base64 | tr -d '\n')
flyctl ssh console -a "$APP" -C "/opt/app/bin/lei_service rpc 'Code.eval_string(Base.decode64!(\"$b64\"))'"
