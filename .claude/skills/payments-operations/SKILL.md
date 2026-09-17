---
name: payments-operations
description: Start here for anything touching LowEndInsight's payments in production -- a payment alert, a customer asking for money back, a Stripe email, a reconciliation discrepancy, a key rotation. Explains how to read payment state with scripts/payments.sh, what an agent may do without asking, and which runbook skill applies.
---

# Payment operations

Money comes in four ways, each with its own kill switch:

| path | what it is |
|---|---|
| `mpp` | agents paying by card over MPP |
| `tempo` | agents paying in stablecoin over MPP (the money moves on chain *before* we see the credential) |
| `acp` | agent card checkout |
| `pro_checkout` | the human Pro plan through Stripe Checkout |

Credits live in an append-only ledger. Refunds and disputes reach it through
Stripe webhooks, never by editing it. See `docs/adr/002-credit-ledger-and-payment-rails.md`.

## Always start by reading state

```bash
scripts/payments.sh status
```

## The interface

Everything below goes through `scripts/payments.sh`. Run it exactly as
`scripts/payments.sh <command>` from the repository root: the permission
rules match that spelling.

- **stdout** is one JSON object with `ok`. Progress is on stderr.
- **exit code:** `0` done *and verified*, `1` refused, failed or not verified,
  `2` bad usage, `4` production unreachable. On `4`, retrying is safe.
- **Every change is verified** by reading it back through a different path
  (`/metrics` or the ledger). `ok: true` without `verified: true` does not
  happen for a change; if you see `not_verified`, stop and escalate.
- **Retrying is safe.** Switching to the current state changes nothing; a
  refund with the same payment, amount and reason reaches the same refund.
- **No secrets** are needed or printed. Never read, echo or paste a key, a token
  or `flyctl secrets list` output into the conversation.

| command | does |
|---|---|
| `status` | switches, held payments, 24h payment outcomes, latest reconciliation |
| `held` | stablecoin payments received while `tempo` was off, awaiting a decision |
| `reconciliation` | the latest ledger-vs-Stripe run with its discrepancies |
| `ledger <pi_…>` | a purchase, everything that reversed it, and the org's balance |
| `switch-off <path> --reason TEXT` | stops a payment path |
| `switch-on <path> --reason TEXT` | restarts it |
| `release <challenge_id>` | credits a held stablecoin payment |
| `refund <pi_…> --reason TEXT [--amount-cents N]` | refunds a credit purchase through Stripe |

Always pass `--actor` with who you are acting for, e.g.
`--actor "agent for <operator>"`.

## Autonomy

**An agent stops money; it does not move money.** Enforced by
`.claude/settings.json`: the second group prompts the operator whatever the
runbook says. This will widen over time; change it there, and in this table.

| an agent may, without asking | needs the operator's approval |
|---|---|
| `status`, `held`, `reconciliation`, `ledger` | `switch-on` |
| `switch-off` | `release` |
| | `refund` |
| | anything with `flyctl ssh`, `flyctl secrets`, `flyctl deploy`, or `stripe` writes |

Switching off is always a safe first move: it stops new payments and credits
nothing, and it is reversible. When in doubt during an incident, switch the
path off, then ask.

## Which runbook

| signal | skill |
|---|---|
| a rail misbehaving; spikes in refusals; `lei_payment_held` > 0 | `payment-path-incident` |
| a customer or operator asks for money back | `payment-refund` |
| a Stripe dispute / chargeback email or `charge.dispute.*` | `payment-chargeback` |
| `lei_stripe_reconciliation` `discrepancies` > 0 or `failed` 1 | `stripe-reconciliation-discrepancy` |
| a key is due, leaked, or suspected | `stripe-key-rotation` |
| Stripe restricts, pauses payouts, or holds the account | `stripe-account-hold` |

## What healthy looks like (`/metrics`)

- `lei_payment_switch_enabled` 1 for every path, unless an incident is open
- `lei_payment_held` 0
- `lei_stripe_reconciliation{measure="failed"} 0`, `discrepancies` 0 (until
  2026-09-21 sandbox shows 2: probe payments `probe-e2e` and
  `probe1789334177083`, which are expected), `age_seconds` under 7200
- `lei_stripe_reversal_events_total{result="unmatched"} 0`
- `lei_stripe_webhook_total{result="invalid"} 0`

## Always

- Record what you did and why in the `--reason`, so the next operator (or
  agent) can undo it.
- Report back: what you saw, what you ran, the JSON result, and what still
  needs a human.
