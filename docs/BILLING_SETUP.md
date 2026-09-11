# Billing Setup

What must exist in Stripe for the ADR-001 pricing model to work, derived from
the code rather than from memory. Every requirement below cites the call site
that depends on it.

**Do this in test mode first.** Test mode exercises checkout, webhooks and
subscription lifecycle identically to live, with no money moving. Going live is
then a credential swap plus a re-verification, not a leap of faith.

## Current state (2026-09-11)

| | |
|---|---|
| Free tier | **Working and verified** — `billing-smoke-test.sh` passes 19/19 against production |
| Pricing calculation | **Correct** — observed `2 cache hits × $0.005 = 1.0 cents` on live traffic |
| Usage recording | **Working** — `/v1/usage` and the dashboard both report it |
| Stripe keys | Test mode (sandbox) |
| Webhook endpoint | Registered and Active, but targets the `fly.dev` hostname |
| Webhook deliveries | None yet — nothing to reconcile |
| Stripe Checkout | Not yet configured |
| Billing meter | `analysis_cost` — create per section 1 |
| Pro tier | Untested end to end |
| ACP self-provisioning | Reachable, but unauthenticated (see below) |

---

## 1. Products, prices and the meter

Your account defaults to API version **`2026-02-25.clover`**, on which Stripe's
legacy metered-billing endpoint (`/v1/subscription_items/{id}/usage_records`) no
longer exists. Usage is reported through **Billing Meters** instead, and
`Lei.Stripe` pins `Stripe-Version` so the account default cannot change this
integration's behaviour without a deploy.

### The meter

| Field | Value |
|---|---|
| Event name | `analysis_cost` |
| Customer mapping | payload key `stripe_customer_id`, type `by_id` |
| Value key | `value` |
| Aggregation | `sum` |

**The unit is a tenth of a cent ($0.001),** chosen so every ADR-001 rate is an
integer: a cache hit ($0.005) is 5 units, a cache miss ($0.05) is 50. Measuring
in whole cents would make a hit 0.5 units and invite rounding drift.

### Prices

| Env var | What it must be |
|---|---|
| `STRIPE_PRO_PRICE_ID` | Recurring price, **$29/month** |
| `STRIPE_METERED_PRICE_ID` | Usage-based price on the `analysis_cost` meter, **graduated**: first **15,000 units at $0**, then **$0.001 per unit** |

The first tier *is* the $15 included credit — 15,000 × $0.001. **Stripe applies
the credit, not the application.** That is deliberate: the previous design
computed overage locally and reported a cumulative figure, which is safe only
with the old replace-semantics endpoint. Meter events are additive, so a
cumulative report would compound — 100, then 250, then 400, billed as 750.
Putting the credit in the price makes that class of error impossible rather
than merely avoided.

### Why there is no daily billing job

`Lei.BillingReporter` was removed. Every analysis emits its own meter event from
`Lei.UsageTracker.record_usage/4`, and Stripe aggregates. No local credit
arithmetic, no cumulative state, no scheduled job to fail silently.

For the record, it never ran: it was not in any supervision tree.

## 2. Checkout session

Created by `Lei.Stripe.create_checkout_session/1` with:

```
mode                     subscription
payment_method_types[0]  card
line_items[0][price]     STRIPE_PRO_PRICE_ID
line_items[1][price]     STRIPE_METERED_PRICE_ID
metadata[org_id]         <org id>
success_url / cancel_url  derived from lei_base_url
```

**`metadata[org_id]` is load-bearing.** The webhook handler reads it to find
which org just paid:

```elixir
org_id = get_in(session, ["metadata", "org_id"])
```

Without it the payment succeeds and the org is never activated — a customer
charged for an account that stays `pending`. Nothing in Stripe will flag this.

## 3. Webhook endpoint

Register **`https://lowendinsight.dev/webhooks/stripe`** subscribed to exactly
these three events, which are the ones `Lei.StripeWebhookHandler` implements:

| Event | Effect |
|---|---|
| `checkout.session.completed` | Sets org `status: "active"`, stores `stripe_customer_id`, `stripe_subscription_id` and `stripe_metered_subscription_item_id` |
| `customer.subscription.deleted` | Deactivates the org |
| `invoice.payment_failed` | Marks the org past due |

`STRIPE_WEBHOOK_SECRET` must be **that endpoint's** signing secret. Each endpoint
has its own; a secret from a different endpoint fails every signature check.

> **Checked 2026-09-11: no reconciliation needed.** Signature verification was
> broken until #62 deployed on 2026-09-08T18:10Z — `conn.private[:raw_body]` was
> always nil, so every event would have returned 400. The Stripe delivery log
> shows **no event deliveries at all**, so no checkout ever completed and no org
> was charged and left `pending`. The bug had no victims.

### Point the endpoint at the canonical domain

The registered endpoint currently targets `https://lowendinsight.fly.dev/webhooks/stripe`
even though the destination is named `lowendinsight.dev`. Both hostnames serve
the same app, so this works — but it makes the fly.dev hostname load-bearing for
billing, and it is the same inconsistency `lei_base_url` had on the redirect
side. Update it to:

```
https://lowendinsight.dev/webhooks/stripe
```

## 4. Environment

| Secret | Set | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | yes | `sk_test_…` today; `sk_live_…` to go live |
| `STRIPE_WEBHOOK_SECRET` | yes | must match the registered endpoint |
| `STRIPE_PRO_PRICE_ID` | yes | verify it points at a test-mode price |
| `STRIPE_METERED_PRICE_ID` | yes | verify it is metered, priced per cent |
| `LEI_BASE_URL` | no | defaults to `https://lowendinsight.dev` |

**Test and live mode have separate objects.** Price IDs, webhook endpoints and
signing secrets created in test mode do not exist in live mode. Switching keys
means replacing all four values, not just the secret key.

## 5. Verification, in test mode

Run in order — each step depends on the previous one having worked.

```bash
# 1. Free tier still healthy
./scripts/billing-smoke-test.sh https://lowendinsight.dev

# 2. Pro checkout: sign up choosing Pro, pay with 4242 4242 4242 4242.
#    Confirm the redirect lands on lowendinsight.dev, not fly.dev.

# 3. Webhook delivered and verified -- Stripe dashboard should show 200,
#    not 400. A 400 means the signing secret does not match.

# 4. The org actually activated. Without this the customer paid for nothing:
#    status should be "active" with stripe_subscription_id and
#    stripe_metered_subscription_item_id populated.

# 5. Metered overage. BillingReporter runs daily and only reports above the
#    included credit (LEI_PRO_TIER_CREDIT_CENTS, default 1500 = $15), so force it:
flyctl ssh console -a lowendinsight \
  -C "/opt/app/bin/lowendinsight_get rpc 'Lei.BillingReporter.report_now()'"
```

Step 5 is the one most likely to be skipped and most likely to be wrong: it is
where a licensed-instead-of-metered price, or a unit mismatch, finally shows up.

## 6. Going live

1. Recreate both prices and the webhook endpoint **in live mode**
2. Replace all four `STRIPE_*` secrets together
3. Re-run section 5 against live keys, using a real card and refunding it
4. Watch the first real invoice end to end rather than assuming it matches

## ACP self-provisioning

`LEI_ACP_BEARER_TOKEN` and `LEI_ACP_SIGNING_SECRET` are **unset**, and
`Lei.Acp.Auth` skips both the bearer and HMAC checks when they are absent.
`POST /acp/checkout` is therefore open to anyone.

For the `lei-free` SKU that may be the intended frictionless self-provisioning
described in ADR-001. It is a live decision either way, not a theoretical one,
and it became live when #62 made the endpoint reachable at all.

Setting either secret turns the corresponding check on.
