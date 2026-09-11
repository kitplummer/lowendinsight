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
| Pro tier | Untested end to end |
| ACP self-provisioning | Reachable, but unauthenticated (see below) |

---

## 1. Products and prices

Two prices, both on the same product or on separate products, attached to the
same subscription.

| Env var | What it must be | Why |
|---|---|---|
| `STRIPE_PRO_PRICE_ID` | Recurring price, **$29/month** | `line_items[0][price]` in `Lei.Stripe.create_checkout_session/1` |
| `STRIPE_METERED_PRICE_ID` | **Metered** usage price, unit = 1 cent | `line_items[1][price]`, and the target of `report_usage/3` |

The metered price **must be metered**, not licensed. `Lei.BillingReporter`
reports overage through `/v1/subscription_items/{id}/usage_records`, which only
exists for metered prices. A licensed price silently accepts the subscription
and then fails every usage report.

**Unit matters.** `BillingReporter.report_for_org/1` reports overage in **integer
cents**, rounded up:

```elixir
overage = Decimal.sub(usage.total_cost_cents, pro_credit)
overage_int = overage |> Decimal.round(0, :up) |> Decimal.to_integer()
stripe.report_usage(org.stripe_metered_subscription_item_id, overage_int, timestamp)
```

So one reported unit = one cent. Price the metered item at $0.01 per unit, or
the bill will be wrong by whatever factor the unit disagrees by.

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
