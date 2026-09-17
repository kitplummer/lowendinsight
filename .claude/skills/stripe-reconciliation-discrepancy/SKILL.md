---
name: stripe-reconciliation-discrepancy
description: Runbook for when the hourly ledger-vs-Stripe reconciliation reports discrepancies, fails, or stops running -- lei_stripe_reconciliation discrepancies above 0, failed 1, or age_seconds over two hours. Covers reading each discrepancy kind and what to do about it.
---

# The ledger and Stripe disagree

Read `payments-operations` first.

## Triggers (`/metrics`)

- `lei_stripe_reconciliation{measure="discrepancies"}` > 0
- `lei_stripe_reconciliation{measure="failed"} 1`
- `lei_stripe_reconciliation{measure="age_seconds"}` > 7200, or `runs 0`

## 1. Read the latest run (agent)

```bash
scripts/payments.sh reconciliation
```

- `status: failed` -- read `error`. Stripe unreachable or rate limited: wait for
  the next hourly run (at :23). `stripe not configured`: escalate. `more than N
  pages`: escalate (volume outgrew the check).
- Not run for over two hours: the Oban job has stopped. Escalate.

**Expected in sandbox until about 2026-09-21:** two `received_not_recorded`,
`probe-e2e` and `probe1789334177083` -- probe payments made directly against
Stripe while building the rails. Not a fault; they age out of the 7-day window.

## 2. Each discrepancy

For each, `scripts/payments.sh ledger <payment_intent>` and act by kind:

| kind | means | do |
|---|---|---|
| `received_not_recorded` | Stripe received a credit purchase the ledger never credited: **a customer paid and got nothing** | Identify the payer from its metadata (`challenge_id`, `acp_session_id`). Propose credit or refund to the operator. A `tempo` payment refused while switched off is *held*, not this: check `scripts/payments.sh held` |
| `missing_in_stripe` | the ledger credited a purchase Stripe has no record of: **credits given for nothing** | Check the Stripe mode matches; escalate. Correcting it is a manual `adjustment:manual` ledger entry by the operator |
| `amount_mismatch` | credited a different amount than Stripe received | Escalate with `ledger_cents` vs `stripe_cents`. More than one on the same rail: `payment-path-incident`, switch the rail off |
| `not_succeeded` | credited a payment that has not succeeded -- a rail granted credit before settlement | A bug. Switch the rail off (`payment-path-incident`) and escalate |
| `mode_mismatch` | recorded against the other mode's Stripe | A half-flipped live cutover (#141). Stop; escalate immediately |
| `refund_not_recorded` | Stripe refunded more than the ledger reversed: credits still spendable | Check the webhook subscribes to `charge.refunded` and `lei_stripe_reversal_events_total{result="unmatched"}`; escalate |

## 3. Report

List each discrepancy, what you found in the ledger, and your proposed action.
Crediting, refunding and ledger adjustments move money and need the operator.
