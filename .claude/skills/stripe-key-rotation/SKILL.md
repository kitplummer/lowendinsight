---
name: stripe-key-rotation
description: Runbook for rotating LowEndInsight's Stripe credentials -- the secret API key, the webhook signing secret -- on schedule, after staff or tool access changes, or because a key may have leaked. Covers the order that avoids an outage and how to verify each step.
---

# Rotate Stripe credentials

Read `payments-operations` first. **Rotation touches credentials: every step
that changes something needs the operator.** A new key is created in the
Stripe Dashboard and entered over stdin by a person; an agent never sees,
handles or prints it.

The detailed procedure, and why each step is ordered as it is, is in
`docs/BILLING_SETUP.md`, "Rotating the webhook signing secret" and "If you are
rotating `STRIPE_SECRET_KEY` instead". This runbook is the checklist around it.

## Suspected leak

Treat as an incident first: `payment-path-incident`, and switch the affected
paths off (agent may) while the operator rotates. A leaked secret key can
refund, and a leaked webhook secret can forge events.

## 1. Before (agent)

```bash
scripts/payments.sh status
curl -s https://lowendinsight.dev/readyz
curl -s https://lowendinsight.dev/metrics | grep -E '^lei_stripe_(mode|webhook_total)'
```

Record: `stripe_mode`, `checks.stripe`, and the webhook counters. These are the
baseline to compare after.

## 2. Roll in Stripe (operator, Dashboard)

- **Secret key:** roll it with the old key expiring in days, not immediately
  (Stripe keeps the old key for up to 7 days).
- **Webhook signing secret:** roll it with the old secret expiring in 24 hours.

Rolling first, expiring later, is what avoids an outage.

## 3. Set it in Fly (operator)

Over stdin, never as an argument:

```bash
read -rs VALUE && printf 'STRIPE_SECRET_KEY=%s\n' "$VALUE" | flyctl secrets import -a lowendinsight && unset VALUE
```

(`STRIPE_WEBHOOK_SECRET` for the webhook secret.) This releases the app.

## 4. Verify (agent)

- `curl -s https://lowendinsight.dev/readyz`: `status ok`, `checks.stripe ok`,
  `stripe_mode` unchanged. `mismatch` means the new key is from the other
  mode or account -- tell the operator immediately; the old key still works
  until it expires.
- webhook secret: after the next real delivery,
  `lei_stripe_webhook_total{result="ok"}` rises and `invalid` stays 0.
  `invalid` rising means the secret is from the wrong endpoint.
- `scripts/payments.sh reconciliation` after the next hourly run: not
  `failed`. A failed run with an authentication error means the key is wrong.

## 5. Expire the old one (operator)

Only after step 4 passes. Then confirm nothing breaks over the next hour of
`/metrics`.
