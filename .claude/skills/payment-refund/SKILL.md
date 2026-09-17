---
name: payment-refund
description: Runbook for refunding a LowEndInsight credit purchase -- an agent or person paid for credits and money should go back, in full or in part. Covers finding the payment, refunding through Stripe, and confirming the credits came back out of the ledger.
---

# Refund a credit purchase

Read `payments-operations` first. **Refunding moves money: it needs the
operator's approval.** An agent prepares and verifies; the refund command
prompts.

Only credit purchases (`mpp`, `tempo`, `acp`) are refunded here. A Pro
subscription is refunded and cancelled in the Stripe Dashboard by the operator;
it does not touch the ledger.

## 1. Find the payment (agent)

You need the PaymentIntent id (`pi_…`). From an operator, a Stripe receipt, or
the MPP `Payment-Receipt` header's `reference`.

```bash
scripts/payments.sh ledger <pi_…>
```

- `not_a_credit_purchase`: not ours to refund here -- stop and report.
- otherwise note `usd_value_cents` on the purchase entry, any existing
  `reversal:` entries (already refunded), and `balance`.

## 2. Decide the amount (with the operator)

- Full: omit `--amount-cents`.
- Partial: `--amount-cents N`, never more than the purchase.
- **Credits already spent** are still reversed in proportion; the org's balance
  can go negative, and the org is refused service until it is positive. Say so
  when proposing a refund on a spent purchase.
- **Stablecoin (`tempo`)** refunds go back on chain to the paying wallet. There
  are no disputes on stablecoin.

## 3. Refund (needs approval)

```bash
scripts/payments.sh refund <pi_…> --reason "<why, and who asked>" [--amount-cents N] --actor "agent for <operator>"
```

The command waits for Stripe's `charge.refunded` webhook to reverse the credits
in the ledger, and only then exits `0` with `"verified": true`.

- Exit `1`, `stripe_refused`: Stripe said no (already refunded, disputed, too
  old). Report `detail`; do not retry with a different reason.
- Exit `1`, `reversal_not_seen`: **Stripe refunded, the ledger did not hear.**
  Money has left and the credits are still spendable. Escalate: check the
  webhook endpoint subscribes to `charge.refunded` (`docs/BILLING_SETUP.md` §3)
  and `lei_stripe_reversal_events_total{result="unmatched"}`.
- Retrying the same command is safe: same payment, amount and reason reach the
  same refund.

## 4. Confirm (agent)

```bash
scripts/payments.sh ledger <pi_…>
```

A new `reversal:<rail>` entry with `kind: refund` and the cumulative
`amount_refunded_cents`; the balance down by the refunded share. The next
hourly reconciliation should show no `refund_not_recorded` for it.
