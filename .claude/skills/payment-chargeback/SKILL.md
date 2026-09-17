---
name: payment-chargeback
description: Runbook for a card dispute (chargeback) on a LowEndInsight payment -- a Stripe dispute email, a charge.dispute event, or credits reversed with kind dispute. Covers what already happened automatically, gathering evidence, and what the operator submits.
---

# A chargeback arrives

Read `payments-operations` first.

Card payments only. Stablecoin (`tempo`) has no disputes.

- **Credit purchases** (`mpp`, `acp`): the ledger reverses credits, below.
- **A Pro subscription payment** (`pro_checkout`) never touched the ledger, so a
  dispute on it reverses nothing and is counted as
  `lei_stripe_reversal_events_total{result="unmatched"}`. Skip to step 3: the
  operator responds, and decides whether to cancel the subscription.

## What has already happened, automatically

- When Stripe **withdraws the funds** (`charge.dispute.funds_withdrawn`), the
  ledger reverses the disputed share of the credits (`reversal:<rail>`,
  `kind: dispute`). The org's balance may go negative.
- If the dispute is **won** (`charge.dispute.funds_reinstated`), exactly those
  credits come back (`reinstatement:<rail>`).
- If it is **lost**, nothing further happens: the funds already left.

Nothing needs switching off for a single dispute.

## 1. Confirm the ledger heard it (agent)

From the dispute: the PaymentIntent (`pi_…`).

```bash
scripts/payments.sh ledger <pi_…>
```

Expect a `reversal:` entry with `kind: dispute`. **None, after the funds were
withdrawn:** the webhook did not arrive or did not match -- escalate, and check
`lei_stripe_reversal_events_total{result="unmatched"}`.

## 2. Gather evidence (agent)

For the operator to decide whether to contest:

- the ledger for the payment: when credits were granted, and how many of them
  were spent (balance before and after)
- for `acp` and `mpp`: the org, its API keys' last use, and usage after the
  purchase -- evidence the service was delivered
- anything suggesting fraud: many disputes from one org or wallet, credits
  spent immediately

Summarise; do not paste API keys, emails or card details into the report.

## 3. Respond (operator, in the Stripe Dashboard)

Submitting evidence or accepting the dispute is the operator's, in the Stripe
Dashboard, before Stripe's deadline on the dispute. An agent does not submit
dispute evidence.

## 4. Afterwards (agent)

When Stripe closes it, confirm with `scripts/payments.sh ledger <pi_…>`: won
shows a `reinstatement:` entry; lost shows only the reversal. Several disputes
on one path in a short time is a signal for `payment-path-incident`.
