---
name: stripe-account-hold
description: Runbook for when Stripe restricts, pauses payouts on, or places a hold on LowEndInsight's account -- a Stripe email about verification, risk review, payouts paused, or charges failing account-wide. Covers stopping new payments, what customers are affected, and what the operator must do.
---

# Stripe holds the account

Read `payments-operations` first.

A hold can stop charges, payouts, or both. Revenue stopping is silent: nothing
in the app fails loudly when payouts pause.

## Triggers

- a Stripe email: account restricted, verification required, payouts paused,
  under review
- `lei_payment_outcomes{outcome="refused"}` rising on every card path at once,
  with `reason="payment_failed"`
- `stripe_refused` from `scripts/payments.sh refund` mentioning the account

## 1. Read state (agent)

```bash
scripts/payments.sh status
curl -s https://lowendinsight.dev/readyz
```

## 2. Stop taking what cannot be honoured (agent may)

**If charges are restricted**, switch off the card paths, so customers are not
asked to pay for something that will fail or be reversed:

```bash
scripts/payments.sh switch-off mpp --reason "Stripe account hold: <summary of Stripe's notice>" --actor "agent for <operator>"
scripts/payments.sh switch-off acp --reason "Stripe account hold: <summary>" --actor "agent for <operator>"
scripts/payments.sh switch-off pro_checkout --reason "Stripe account hold: <summary>" --actor "agent for <operator>"
```

**`tempo` too**, if the hold covers crypto: stablecoin sent while `tempo` is on
settles into the same Stripe account. Switching it off holds any in flight.

**If only payouts are paused**, payments still settle into the balance: leave
the paths on, and tell the operator.

Existing customers' credits and Pro subscriptions keep working; nothing here
revokes service already paid for.

## 3. Operator actions (needs the operator)

- respond to Stripe: verification documents, business information, whatever
  the notice asks, in the Stripe Dashboard
- decide what to tell customers
- if the hold is prolonged: this is a business decision, not a runbook step

## 4. After the hold lifts (needs approval)

`payment-path-incident` step 5, per path: switch back on with the reason, and
confirm `issued` and `settled` resume. Check `scripts/payments.sh held` for
stablecoin held while `tempo` was off, and
`scripts/payments.sh reconciliation` for anything that failed mid-hold.
