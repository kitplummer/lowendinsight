#!/usr/bin/env bash
#
# The executable interface to the payment runbooks (#139).
#
# Written to be run by an agent as much as by a person, so:
#
#   * stdout is exactly one JSON object with an "ok" field; progress goes to
#     stderr
#   * the exit code means something: 0 done and verified, 1 refused, failed or
#     not verified, 2 bad usage, 4 production could not be reached
#   * every change is verified by reading it back through a different path
#     than the one that made it (the public /metrics, or the ledger)
#   * repeating a command is safe: switching to the current state changes
#     nothing, and a refund is keyed so a retry reaches the same refund
#   * no secret is read, passed or printed here. Operations run inside the
#     production machine over `flyctl ssh`, as Lei.Operations over rpc, with
#     their arguments as base64 JSON -- nothing an agent passes is evaluated.
#
# In a Claude Code session, .claude/settings.json makes the subcommands that
# move money prompt before they run.
#
#   scripts/payments.sh status
#   scripts/payments.sh switch-off <path> --reason TEXT [--actor NAME]
#   scripts/payments.sh switch-on  <path> --reason TEXT [--actor NAME]
#   scripts/payments.sh held
#   scripts/payments.sh release <challenge_id> [--actor NAME]
#   scripts/payments.sh ledger <payment_intent>
#   scripts/payments.sh reconciliation
#   scripts/payments.sh refund <payment_intent> --reason TEXT [--amount-cents N] [--actor NAME]
#
#   paths: mpp tempo acp pro_checkout
#
# Environment: LEI_APP (lowendinsight), LEI_BASE_URL (https://lowendinsight.dev),
# PAYMENTS_VERIFY_ATTEMPTS (30), PAYMENTS_VERIFY_INTERVAL (2, seconds).

set -uo pipefail

APP="${LEI_APP:-lowendinsight}"
BASE_URL="${LEI_BASE_URL:-https://lowendinsight.dev}"
ATTEMPTS="${PAYMENTS_VERIFY_ATTEMPTS:-30}"
INTERVAL="${PAYMENTS_VERIFY_INTERVAL:-2}"
PATHS="mpp tempo acp pro_checkout"

log() { printf '%s\n' "$*" >&2; }

# One JSON object on stdout, then exit.
finish() {
  local code="$1" json="$2"
  printf '%s\n' "$json"
  exit "$code"
}

# The exit code for an operation's JSON: 0 ok, 4 unreachable, 1 anything else.
# operation() runs in a subshell, so it cannot exit for its caller; this does.
respond() {
  local json="$1"
  if printf '%s' "$json" | jq -e '.ok == true' >/dev/null 2>&1; then finish 0 "$json"; fi
  if [ "$(printf '%s' "$json" | jq -r '.error // empty' 2>/dev/null)" = "unreachable" ]; then finish 4 "$json"; fi
  finish 1 "$json"
}

usage() {
  finish 2 "$(jq -cn --arg detail "$1" '{ok: false, error: "usage", detail: $detail}')"
}

need() { command -v "$1" >/dev/null 2>&1 || finish 4 "$(jq -cn --arg t "$1" '{ok:false, error:"missing_tool", detail:$t}' 2>/dev/null || printf '{"ok":false,"error":"missing_tool"}')"; }

valid_path() { [[ " $PATHS " == *" $1 "* ]]; }
valid_id() { [[ "$1" =~ ^[A-Za-z0-9_-]{1,128}$ ]]; }

# Runs Lei.Operations.cli(command, args) inside production and prints its JSON.
operation() {
  local command="$1" args_json="$2" encoded out json
  encoded=$(printf '%s' "$args_json" | base64 | tr -d '\n')

  out=$(flyctl ssh console -a "$APP" \
    -C "/opt/app/bin/lei_service rpc 'IO.puts(Lei.Operations.cli(\"${command}\", \"${encoded}\"))'" 2>&1)

  json=$(printf '%s\n' "$out" | grep -E '^\{.*\}$' | tail -1)

  if [ -z "$json" ] || ! printf '%s' "$json" | jq -e 'has("ok")' >/dev/null 2>&1; then
    json=$(jq -cn --arg detail "$(printf '%s' "$out" | tail -5)" \
      '{ok: false, error: "unreachable", detail: $detail}')
  fi

  printf '%s' "$json"
}

# The switch as the public /metrics reports it: 1, 0, or empty if unreadable.
metric_switch() {
  curl -s --max-time 15 "${BASE_URL}/metrics" |
    sed -n "s/^lei_payment_switch_enabled{path=\"$1\"} \\([01]\\)$/\\1/p"
}

# Cents the ledger has reversed for refunds of this PaymentIntent (cumulative).
refunded_in_ledger() {
  operation ledger "$(jq -cn --arg pi "$1" '{payment_intent: $pi}')" |
    jq '[.entries[]? | select(.reason | startswith("reversal:")) | .metadata.amount_refunded_cents // 0] | max // 0'
}

parse_flags() {
  REASON="" ACTOR="scripts/payments.sh" AMOUNT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) REASON="${2:-}"; shift 2 ;;
      --actor) ACTOR="${2:-}"; shift 2 ;;
      --amount-cents) AMOUNT="${2:-}"; shift 2 ;;
      *) usage "unknown option: $1" ;;
    esac
  done
}

switch() {
  local enabled="$1" path="${2:-}" expected result
  shift 2 2>/dev/null || true
  valid_path "$path" || usage "path must be one of: $PATHS"
  parse_flags "$@"
  [ -n "${REASON// /}" ] || usage "--reason is required: whoever reverses this needs to know why"

  result=$(operation switch "$(jq -cn --arg path "$path" --argjson enabled "$enabled" \
    --arg reason "$REASON" --arg actor "$ACTOR" \
    '{path: $path, enabled: $enabled, reason: $reason, actor: $actor}')")

  printf '%s' "$result" | jq -e '.ok == true' >/dev/null || respond "$result"

  expected=$([ "$enabled" = true ] && echo 1 || echo 0)
  for _ in $(seq 1 "$ATTEMPTS"); do
    if [ "$(metric_switch "$path")" = "$expected" ]; then
      finish 0 "$(printf '%s' "$result" | jq -c '. + {verified: true, verified_by: "/metrics"}')"
    fi
    sleep "$INTERVAL"
  done

  log "switch recorded, but /metrics does not show lei_payment_switch_enabled{path=\"$path\"} $expected"
  finish 1 "$(printf '%s' "$result" | jq -c '. + {ok: false, verified: false, error: "not_verified"}')"
}

refund() {
  local pi="${1:-}" result args total before
  shift 1 2>/dev/null || true
  valid_id "$pi" || usage "a payment_intent id is required"
  parse_flags "$@"
  [ -n "${REASON// /}" ] || usage "--reason is required"
  if [ -n "$AMOUNT" ] && ! [[ "$AMOUNT" =~ ^[1-9][0-9]*$ ]]; then usage "--amount-cents must be a positive integer"; fi

  args=$(jq -cn --arg pi "$pi" --arg reason "$REASON" --arg actor "$ACTOR" --arg amount "$AMOUNT" \
    '{payment_intent: $pi, reason: $reason, actor: $actor}
     + (if $amount == "" then {} else {amount_cents: ($amount | tonumber)} end)')

  # What the ledger has already recorded as refunded, so a second partial
  # refund is not "verified" by the reversal of the first.
  before=$(refunded_in_ledger "$pi")

  result=$(operation refund "$args")
  printf '%s' "$result" | jq -e '.ok == true' >/dev/null || respond "$result"

  # The ledger follows the money: the reversal arrives with Stripe's
  # charge.refunded webhook, not with the refund call.
  for _ in $(seq 1 "$ATTEMPTS"); do
    total=$(refunded_in_ledger "$pi")
    if [ "${total:-0}" -gt "${before:-0}" ]; then
      finish 0 "$(printf '%s' "$result" | jq -c --argjson seen "$total" \
        '. + {verified: true, verified_by: "ledger", ledger_refunded_cents: $seen}')"
    fi
    sleep "$INTERVAL"
  done

  log "Stripe accepted the refund, but no reversal reached the ledger: check the webhook"
  finish 1 "$(printf '%s' "$result" | jq -c '. + {ok: false, verified: false, error: "reversal_not_seen"}')"
}

need jq
need flyctl
need curl

command="${1:-}"
shift 2>/dev/null || true

case "$command" in
  status)
    respond "$(operation status '{}')"
    ;;
  held | reconciliation)
    respond "$(operation "$command" '{}')"
    ;;
  switch-off) switch false "$@" ;;
  switch-on) switch true "$@" ;;
  ledger)
    valid_id "${1:-}" || usage "a payment_intent id is required"
    respond "$(operation ledger "$(jq -cn --arg pi "$1" '{payment_intent: $pi}')")"
    ;;
  release)
    valid_id "${1:-}" || usage "a challenge id is required"
    result=$(operation release "$(jq -cn --arg id "$1" '{challenge_id: $id}')")
    printf '%s' "$result" | jq -e '.ok == true' >/dev/null || respond "$result"
    pi=$(printf '%s' "$result" | jq -r '.payment_intent')
    ledger=$(operation ledger "$(jq -cn --arg pi "$pi" '{payment_intent: $pi}')")
    if printf '%s' "$ledger" | jq -e '.ok' >/dev/null; then
      finish 0 "$(printf '%s' "$result" | jq -c '. + {verified: true, verified_by: "ledger"}')"
    fi
    finish 1 "$(printf '%s' "$result" | jq -c '. + {ok: false, verified: false, error: "not_in_ledger"}')"
    ;;
  refund) refund "$@" ;;
  "" | -h | --help) usage "commands: status switch-off switch-on held release ledger reconciliation refund" ;;
  *) usage "unknown command: $command" ;;
esac
