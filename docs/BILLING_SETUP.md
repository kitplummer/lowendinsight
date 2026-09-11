# Billing Setup

What must exist in Stripe for the ADR-001 pricing model to work, derived from
the code rather than from memory. Every requirement below cites the call site
that depends on it.

**Do this in test mode first.** Test mode exercises checkout, webhooks and
subscription lifecycle identically to live, with no money moving. Going live is
then a credential swap plus a re-verification, not a leap of faith.

## Current state (2026-09-11)

**The Pro path is verified end to end in sandbox.** Every step below was
exercised against production with a real Stripe Checkout, not simulated.

| | |
|---|---|
| Free tier | **Verified** — `billing-smoke-test.sh` passes 19/19 against production |
| Pro checkout | **Verified** — org created `tier: "pro"`, activated by webhook |
| Stripe webhook | **Verified** — `POST /webhooks/stripe` returned 200; signature matches |
| Success redirect | **Verified** — lands on `lowendinsight.dev` |
| Usage recording | **Verified** — 2 cache misses recorded as `total_cost_cents: 10.0` |
| Meter events | **Verified** — `aggregated_value: 100` in Stripe |
| Included credit | **Verified** — 15,000-unit tier absorbs it; amount due stays $29 |
| `POST /v1/analyze` | **Verified** authenticated (was raising until #91/#92) |
| Stripe keys | Test mode (sandbox) — live mode still to do |
| ACP self-provisioning | Reachable but **unauthenticated** — see below |

### The verified chain

```
2 cache misses x $0.05          = $0.10
  -> UsageTracker.calculate_cost  = 10.0 cents
  -> to_meter_units (x10)         = 100 units
  -> meter event, keyed by customer
  -> Stripe aggregates            = 100        <- observed
```

That the numbers land exactly on ADR-001's figures is the evidence the
tenth-of-a-cent unit was the right choice: 15,000 units is $15.00, which is
3,000 cache hits or 300 misses, matching the stated Pro credit without adjustment.

### Sandbox objects created

| Object | ID |
|---|---|
| Meter | `mtr_test_61VNt1N74r40DMKnn4136n3SNNombE1Q` |
| Product | `prod_VEzHnMVO4j6RDi` |
| Pro price ($29/mo) | `price_1UEVQx36n3SNNomb9bwoiS5M` |
| Metered price (graduated) | `price_1UEVRK36n3SNNombFIKvyqje` |

These are **test-mode objects and do not exist in live mode.** Section 6.

### Defects found by running the flow

Five, none of which code review had surfaced:

| Defect | Fixed in |
|---|---|
| `/signup/success` raised — customer paid, saw a 500, never received their key | #90 |
| Pro signup reusing an existing name silently stayed on the free tier | #89 |
| Unauthenticated signup issued admin keys for **existing** orgs | #89 |
| `POST /v1/analyze` raised for every authenticated caller | #91 |
| Metered billing used an API removed from the account's version, and never captured the subscription item, and its reporter was never started | #88 |

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

**Completed 2026-09-11.** Re-run this whole sequence after switching to live
keys; passing in sandbox does not carry over, because live mode has entirely
separate objects.

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

Nothing from sandbox carries over. Test and live mode hold entirely separate
meters, products, prices, webhook endpoints and signing secrets.

1. Recreate **in live mode**: the `analysis_cost` meter, the product, both prices
   (including the graduated first tier), and the webhook endpoint
2. Replace all four `STRIPE_*` secrets **together** — a live secret key paired
   with a test price ID fails in a way that looks like a pricing bug
3. Re-run **all** of section 5 against live keys, with a real card, then refund
4. Watch the first real invoice line by line rather than assuming it matches

The sandbox run found five defects, four of them customer-facing. Treat the live
run as a real test, not a formality.

## ACP self-provisioning

`LEI_ACP_BEARER_TOKEN` and `LEI_ACP_SIGNING_SECRET` are **unset**, and
`Lei.Acp.Auth` skips both the bearer and HMAC checks when they are absent.
`POST /acp/checkout` is therefore open to anyone.

For the `lei-free` SKU that may be the intended frictionless self-provisioning
described in ADR-001. It is a live decision either way, not a theoretical one,
and it became live when #62 made the endpoint reachable at all.

Setting either secret turns the corresponding check on.
