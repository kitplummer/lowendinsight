#!/usr/bin/env bash
#
# Renders the weekly adoption report from production's /metrics.
#
#   scripts/ops/adoption-report.sh <metrics-file> [<previous-report-file>] [--intro]
#
# Lei.Adoption counts analysis calls per client bucket, and /metrics publishes
# them, but nothing read them: the question they answer -- does anyone use
# this, and through which door -- went unasked. .github/workflows/
# adoption-report.yml runs this every week and keeps the result in one running
# GitHub issue, where a person or an agent can act on it.
#
# <previous-report-file> is last week's report (the issue body); its data block
# gives the change column. --intro prepends the issue's standing explanation.
#
# Fails rather than reporting zeros: an unreadable counter or a missing bucket
# is "we could not tell", which is the opposite finding to "nobody called".
set -uo pipefail

METRICS=""; PREVIOUS=""; INTRO=0
for arg in "$@"; do
  case "$arg" in
    --intro) INTRO=1 ;;
    *) if [ -z "$METRICS" ]; then METRICS="$arg"; else PREVIOUS="$arg"; fi ;;
  esac
done
[ -n "$METRICS" ] || { echo "usage: $0 <metrics-file> [<previous-report-file>] [--intro]" >&2; exit 2; }

# Lei.Adoption.buckets/0. adoption_report_test.exs holds the two together.
BUCKETS="mcp mcp-remote cli internal agent script browser other none"

if ! grep -qx 'lei_adoption_readable 1' "$METRICS"; then
  echo "::error::/metrics does not report lei_adoption_readable 1: the adoption counters could not be read, so there is no report -- not a report of zero."
  exit 1
fi

gauge() { sed -n "s/^$1{client=\"$2\"} \([0-9][0-9]*\)$/\1/p" "$METRICS" | head -1; }

TODAY_JSON="{}"; MONTH_JSON="{}"; WEEK_CALLERS_JSON="{}"; MONTH_CALLERS_JSON="{}"
for b in $BUCKETS; do
  t=$(gauge lei_adoption_calls "$b"); m=$(gauge lei_adoption_calls_30d "$b")
  c7=$(gauge lei_adoption_callers_7d "$b"); c30=$(gauge lei_adoption_callers_30d "$b")
  if [ -z "$t" ] || [ -z "$m" ] || [ -z "$c7" ] || [ -z "$c30" ]; then
    echo "::error::/metrics has no adoption count for client \"$b\". A missing bucket reads as zero in a table, so this is a failure."
    exit 1
  fi
  TODAY_JSON=$(jq -c --arg b "$b" --argjson v "$t" '.[$b] = $v' <<<"$TODAY_JSON")
  MONTH_JSON=$(jq -c --arg b "$b" --argjson v "$m" '.[$b] = $v' <<<"$MONTH_JSON")
  WEEK_CALLERS_JSON=$(jq -c --arg b "$b" --argjson v "$c7" '.[$b] = $v' <<<"$WEEK_CALLERS_JSON")
  MONTH_CALLERS_JSON=$(jq -c --arg b "$b" --argjson v "$c30" '.[$b] = $v' <<<"$MONTH_CALLERS_JSON")
done

# One count across clients, not the column's sum: an organisation calling
# through two clients is under both, and is one caller.
EXT7=$(sed -n 's/^lei_adoption_external_callers_7d \([0-9][0-9]*\)$/\1/p' "$METRICS" | head -1)
EXT30=$(sed -n 's/^lei_adoption_external_callers_30d \([0-9][0-9]*\)$/\1/p' "$METRICS" | head -1)
if [ -z "$EXT7" ] || [ -z "$EXT30" ]; then
  echo "::error::/metrics has no count of external callers. A missing count reads as zero, so this is a failure."
  exit 1
fi

DATE="${ADOPTION_REPORT_DATE:-$(date -u +%F)}"
DATA=$(jq -cn --arg d "$DATE" --argjson t "$TODAY_JSON" --argjson m "$MONTH_JSON" \
  --argjson c7 "$WEEK_CALLERS_JSON" --argjson c30 "$MONTH_CALLERS_JSON" \
  --argjson e7 "$EXT7" --argjson e30 "$EXT30" \
  '{date: $d, calls_today: $t, calls_30d: $m, callers_7d: $c7, callers_30d: $c30,
    external_callers_7d: $e7, external_callers_30d: $e30}')

PREV_DATA=""
if [ -n "$PREVIOUS" ] && [ -s "$PREVIOUS" ]; then
  PREV_DATA=$(sed -n '/^<!-- adoption-data/,/^```$/p' "$PREVIOUS" | sed -n '/^{/p' | head -1)
  jq -e . >/dev/null 2>&1 <<<"$PREV_DATA" || PREV_DATA=""
fi
PREV_DATE=$(jq -r '.date // empty' <<<"${PREV_DATA:-{\}}")

if [ "$INTRO" -eq 1 ]; then
  cat <<'EOF'
The running adoption report for lowendinsight.dev, updated every Monday by `.github/workflows/adoption-report.yml`. The body is always the latest report; each week's is also posted as a comment, so the thread is the history. Do not close this issue: the workflow writes to the open issue labelled `adoption-report` and makes a new one if there is none.

**Reading it.** Calls to the analysis (`/v1/analyze*`, the Try It form, and `/mcp`'s `check_packages` and `analyze_repositories`), bucketed by client in `Lei.Adoption`:
`mcp-remote` is anything connecting to `/mcp`; `agent` is a user agent naming an AI client; `script` is curl, requests and the like; `browser` is a person; `internal` is our own smoke test and canary, which name themselves `lowendinsight-monitor/1`; `other` is a user agent no bucket recognises; `none` sent no user agent.

Calls say how much; callers say how many. A caller is an organisation when it used an API key (one customer with several keys is one caller) and otherwise an address, which is never stored. One agent in a retry loop is many calls and one caller. Callers are counted from November 2026, so until a window has passed since then the callers columns cover less than their full span.

**Acting on it** (for a person or an agent):
- `mcp-remote` at zero after the MCP Registry listing is published (`server.json`): check the listing resolves and `apps/lei_service/docs/MCP.md`'s setup still works.
- `other` growing: a client the buckets do not know. Look at what it is and, if it matters, add a bucket in `Lei.Adoption`.
- One external bucket's calls jumping in a week while its callers stay flat: a single caller. Check it is not something rate limiting should have stopped.
- External callers, 7 days, is the number that says whether anyone new is arriving. Calls without callers growing is the same few users using it more.
- `internal` falling to zero: the probes stopped running or stopped naming themselves, and their calls are being counted as adoption again.

The block marked `adoption-data` is the machine-readable copy of each report.

---

EOF
fi

total_external() { jq -r '[to_entries[] | select(.key != "internal") | .value] | add' <<<"$1"; }

echo "## Adoption, ${DATE}"
echo
if [ -n "$PREV_DATE" ]; then
  echo "| client | calls today | calls, 30 days | callers, 7 days | callers, 30 days | 30-day calls, change since ${PREV_DATE} |"
  echo "|---|--:|--:|--:|--:|--:|"
else
  echo "| client | calls today | calls, 30 days | callers, 7 days | callers, 30 days |"
  echo "|---|--:|--:|--:|--:|"
fi
for b in $BUCKETS; do
  t=$(jq -r --arg b "$b" '.[$b]' <<<"$TODAY_JSON"); m=$(jq -r --arg b "$b" '.[$b]' <<<"$MONTH_JSON")
  c7=$(jq -r --arg b "$b" '.[$b]' <<<"$WEEK_CALLERS_JSON"); c30=$(jq -r --arg b "$b" '.[$b]' <<<"$MONTH_CALLERS_JSON")
  if [ -n "$PREV_DATE" ]; then
    p=$(jq -r --arg b "$b" '.calls_30d[$b] // empty' <<<"$PREV_DATA")
    if [ -n "$p" ]; then d=$((m - p)); [ "$d" -gt 0 ] && d="+$d"; else d="new"; fi
    echo "| \`$b\` | $t | $m | $c7 | $c30 | $d |"
  else
    echo "| \`$b\` | $t | $m | $c7 | $c30 |"
  fi
done
echo
echo "**External calls, last 30 days:** $(total_external "$MONTH_JSON") (everything but \`internal\`)"
echo
echo "**External callers, last 7 days:** ${EXT7}; last 30 days: ${EXT30} (one count across clients, without \`internal\`)"
echo
echo "**Remote MCP, last 30 days:** $(jq -r '."mcp-remote"' <<<"$MONTH_JSON") calls from $(jq -r '."mcp-remote"' <<<"$MONTH_CALLERS_JSON") callers"
echo
echo "<!-- adoption-data: the numbers above, for an agent to read -->"
echo '```json'
echo "$DATA"
echo '```'
