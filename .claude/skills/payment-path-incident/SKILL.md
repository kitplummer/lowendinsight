---
name: payment-path-incident
description: Runbook for a payment path misbehaving in production -- charging or crediting wrongly, a spike in refused payments, a rail issuing challenges and settling none, or held stablecoin payments waiting. Switch the path off, investigate, decide held payments, and switch back on.
---

# A payment path is misbehaving

Read `payments-operations` first for the interface and autonomy.

## Triggers

- `lei_payment_outcomes{outcome="refused"}` spiking for one rail, especially
  `reason="challenge_mismatch"` (forged credentials) or
  `reason="payment_not_settled"` (network trouble)
- `outcome="issued"` rising while `outcome="settled"` stays 0 for a rail
- reconciliation showing `amount_mismatch` or `not_succeeded` (credits granted
  wrongly: see also `stripe-reconciliation-discrepancy`)
- `lei_payment_held{rail="tempo"}` > 0
- an operator saying a path is wrong

## 1. Read state (agent)

```bash
scripts/payments.sh status
```

Note which path, since when, and the outcome counts.

## 2. Switch the path off (agent, no approval needed)

When money is being taken or credited wrongly, do not wait.

```bash
scripts/payments.sh switch-off <path> --reason "<what is wrong, evidence, and where tracked>" --actor "agent for <operator>"
```

Expect exit `0` and `"verified": true`. Exit `1` with `not_verified`: the
change was recorded but `/metrics` does not show it -- escalate immediately.
Exit `4`: production unreachable; retry, then escalate.

What off does:

- `mpp`, `tempo`: no new challenges; credentials refused, **not credited**.
  A `tempo` credential refused while off is **held** (step 4).
- `acp`: no sessions opened or completed; nothing charged.
- `pro_checkout`: no Checkout started. A checkout already paid at Stripe is not
  applied; Stripe retries its webhook for up to three days and it applies when
  the switch is back on.

The canary skips its stablecoin check while `tempo` is off, so a deploy during
the incident is not rolled back for it.

## 3. Investigate (agent)

- `scripts/payments.sh reconciliation` -- does the ledger disagree with Stripe?
- `scripts/payments.sh ledger <pi_…>` for affected payments
- application logs are an operator action (`flyctl logs`): ask

Report findings. Fixing code is a normal PR, not part of this runbook.

## 4. Held stablecoin payments (decide with the operator)

```bash
scripts/payments.sh held
```

Each is money an agent sent while `tempo` was off. For each, propose one:

- **credit it** -- the payment was good:
  `scripts/payments.sh release <challenge_id> --actor "…"` (**needs approval**).
  Verifies the transfer and credits once, even with `tempo` still off.
- **refund it** -- release it first (Stripe records a stablecoin payment only
  once verified, so there is nothing to refund before), then follow
  `payment-refund` with the `payment_intent` from the release output.

Done when `lei_payment_held` is 0.

## 5. Switch back on (needs approval)

Only when the cause is fixed or understood, and held payments are decided.

```bash
scripts/payments.sh switch-on <path> --reason "<why it is safe now>" --actor "agent for <operator>"
```

Then confirm with `status`: `issued` rising again for the path, and `settled`
following. For `pro_checkout`, the operator confirms in the Stripe Dashboard
that retried `checkout.session.completed` deliveries succeed.

## Escalate, and stop, if

- any command returns `not_verified`
- `held` payments you cannot attribute
- the ledger and Stripe disagree in a way the runbook does not name
