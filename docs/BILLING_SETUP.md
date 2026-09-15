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
| Usage recording | **Verified** — 4 cache misses recorded as `total_cost_cents: 20.0` |
| Meter events | **Verified against Stripe** — `aggregated_value: 200.0` |
| Subscription | **Verified** — `active`, both line items attached |
| ACP rate limiting | **Verified in production** — 20 x 201 then 429, `retry-after: 58` |
| Included credit | **Verified** — 15,000-unit tier absorbs it; amount due stays $29 |
| `POST /v1/analyze` | **Verified** authenticated (was raising until #91/#92) |
| Stripe keys | Test mode (sandbox) — live mode still to do |
| ACP self-provisioning | Reachable but **unauthenticated** — see below |

### The verified chain

Confirmed from both ends -- the application's own records, and Stripe's.

```
4 cache misses x $0.05          = $0.20
  -> UsageTracker.calculate_cost  = 20.0 cents      <- /v1/usage
  -> to_meter_units (x10)         = 200 units
  -> meter event, keyed by customer
  -> Stripe aggregates            = 200.0           <- observed
```

That total accumulated across **two separate batches**, which is the part worth
noting: it went 100 -> 200 with distinct idempotency identifiers. Deduplication
is discriminating correctly rather than suppressing legitimate usage, which is
the failure mode adding an idempotency key introduces.

### Subscription structure

```
sub_1UEWPV36n3SNNombezdApuys | active
  licensed  price_1UEVQx...  unit_amount=2900   <- $29/month base
  metered   price_1UEVRK...  unit_amount=None   <- pricing lives in the tiers
```

`unit_amount=None` on the metered price is correct for a graduated price: the
amount comes from the tiers, not a flat rate. A number there would mean the
tiers were not applied.

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
| Test customer | `cus_VF0Q3ox3rjYHmr` |
| Test subscription | `sub_1UEWPV36n3SNNombezdApuys` |

These live in sandbox account `acct_1T8rhd36n3SNNomb`. **Note the account id
fragment `36n3SNNomb` appears inside every object id** -- useful for spotting
when a query has been pointed at the wrong Stripe context, which returns a
valid, empty result rather than an error.

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

### Rotating the webhook signing secret

Signing secrets do not expire on their own. The expiry you set when rolling
applies to the **previous** secret, not the new one -- it is how long Stripe
keeps accepting the old signature while you migrate, up to 24 hours. During
that window Stripe signs each event with both secrets, so there is no cutover
gap unless you choose one.

Do it in this order. Rolling last is what creates an outage.

1. **Roll in the Stripe Dashboard** with the old secret expiring in **24 hours**,
   not immediately. Webhooks keep working throughout.

2. **Set it in Fly**, without the value entering argv or shell history:

   ```bash
   read -rs STRIPE_WH && printf 'STRIPE_WEBHOOK_SECRET=%s\n' "$STRIPE_WH" \
     | flyctl secrets import -a lowendinsight && unset STRIPE_WH
   ```

   This triggers a release. Use `--stage` and a separate `flyctl deploy` if you
   are changing several secrets together.

   Do **not** use `flyctl secrets set KEY=value` -- the value is visible in
   `ps` and lands in shell history.

3. **Verify with a real delivery.** The digest changing proves only that
   *something* changed. Resend a recent event from the Dashboard and confirm a
   200, or watch the app:

   ```bash
   flyctl logs -a lowendinsight | grep -i webhook
   ```

   A mismatch logs `STRIPE_WEBHOOK_SECRET is set but does not match the sending
   endpoint`.

4. **Check the counters** once traffic has flowed:

   ```bash
   curl -s https://lowendinsight.dev/metrics | grep lei_stripe_webhook_total
   ```

   `result="ok"` should be increasing. Any `result="invalid"` means the secret
   does not match; `result="unconfigured"` means it is not set at all.
   `result="unsigned"` is internet scanners hitting a public URL and is not a
   problem.

The `monitor` workflow checks these every 15 minutes and fails on `invalid` or
`unconfigured`, so a botched rotation surfaces on its own. That check exists
because a wrong secret is indistinguishable from an unset one from the outside:
every delivery 400s, subscriptions quietly stop activating, and nothing else
changes.

The 24-hour grace period is also why this failure arrives *late* -- the
breakage appears a day after the change that caused it, by which point the two
are easy not to connect.

#### If you are rotating `STRIPE_SECRET_KEY` instead

Different mechanism, different number: rotating an API key keeps the old one
working for up to **7 days**, not 24 hours. Same ordering applies -- rotate,
update Fly, verify, and let the old key lapse rather than revoking it first.

## 4. Environment

| Secret | Set | Notes |
|---|---|---|
| `STRIPE_SECRET_KEY` | yes | `sk_test_…` today; `sk_live_…` to go live |
| `STRIPE_WEBHOOK_SECRET` | yes | must match the registered endpoint |
| `STRIPE_PRO_PRICE_ID` | yes | verify it points at a test-mode price |
| `STRIPE_METERED_PRICE_ID` | yes | verify it is metered, priced per cent |
| `STRIPE_PROFILE_ID` | **not yet** | `profile_test_…` in sandbox, `profile_…` live. Agents' Shared Payment Tokens are scoped to it; without it the MPP rail answers 402 with `payment: "unavailable"` and no challenge (#143) |
| `TEMPO_DEPOSIT_ADDRESS` | **not yet** | a Stripe crypto deposit address on Tempo, created with the same key (below). Without it, or until Stripe confirms it belongs to the key's account, 402s offer no stablecoin challenge (#144) |
| `LEI_BASE_URL` | no | defaults to `https://lowendinsight.dev` |

**Test and live mode have separate objects.** Price IDs, webhook endpoints and
signing secrets created in test mode do not exist in live mode. Switching keys
means replacing all five values, not just the secret key.

### Stablecoin deposit address (#144)

One address per mode, created with that mode's key. The endpoint is a preview API, so it needs the preview version header:

```bash
# Run where STRIPE_SECRET_KEY is the key for the mode you are configuring.
# List first -- an address may already exist.
curl -G https://api.stripe.com/v1/crypto/deposit_addresses \
  -u "$STRIPE_SECRET_KEY:" -H "Stripe-Version: 2026-07-29.preview" -d network=tempo

curl https://api.stripe.com/v1/crypto/deposit_addresses \
  -u "$STRIPE_SECRET_KEY:" -H "Stripe-Version: 2026-07-29.preview" -d network=tempo
```

The sandbox address is `0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c` (`cda_1UFN8E36n3SNNomb2KUhVIWG`). An address isn't a secret, but it switches with the key, so it goes in with the other `STRIPE_*` values:

```bash
printf 'TEMPO_DEPOSIT_ADDRESS=0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c\n' | flyctl secrets import -a lowendinsight
```

How a stablecoin payment is verified (behaviour observed in sandbox against real testnet transfers):

1. The challenge carries a random memo, our address, the token, and the exact amount
2. The agent transfers on Tempo and presents the transaction hash
3. We read the receipt over Tempo JSON-RPC: `TransferWithMemo`, right token, our address, this memo, exact amount. This is **attribution**; hashes are public
4. Stripe `transaction_verification` PaymentIntent: `processing`, then `succeeded` in about 5s. Stripe checks recipient and amount itself, and refuses to track one transfer twice
5. Credits on `succeeded` only. Still `processing` after 20s → 402, and the agent retries the same credential

Minimum is **$0.50**. Stripe rejects smaller crypto PaymentIntents, although its docs say 0.01 USDC.

### An agent from nothing (#147)

`POST /v1/analyze`, `POST /v1/analyze/batch` and `POST /v1/analyze/sbom` are the only routes that accept a request with no credentials, and they answer it with a 402. Everything else under `/v1` still returns 401.

**Pricing a request (#152).** `/v1/analyze` and `/v1/analyze/sbom` price a request before running it: each repository with a cached report is a hit, anything else a miss.
- **Charged when accepted**, including async, stale and timed-out requests. It had been billed from the response's cache counts, which those responses don't carry, so they were free.
- **Top-ups cover the whole request:** a credit-funded org holding less than the price is asked to top up by at least the shortfall.
- **Batch is unchanged:** it bills from `BatchAnalyzer`'s summary, which is synchronous.

**The Try It form** (`GET /url=`) serves cached reports freely. Fresh analyses are limited per IP (`rate_limits.try_it`, per `rate_limit_windows.try_it`: 10 an hour by default) and checked before any work.

```
POST /v1/analyze                          (no Authorization)
  <- 402  WWW-Authenticate: Payment ... method="tempo"
POST /v1/analyze                          Authorization: Payment <credential>
  <- 200  Payment-Receipt: ...   Lei-Api-Key: lei_...
POST /v1/analyze                          Authorization: Bearer lei_...
  <- 200                                  (spends the balance, no payment)
```

- **Only stablecoin is offered anonymously.** The org belongs to the wallet that paid, taken from the transfer on chain, and that wallet must also be the transaction's signer (not an approved spender). A card token identifies no one, so card challenges are offered only to callers that already have an org.
- **Create-only:** a wallet with an existing org is credited there. Anyone who can pay from that wallet controls it.
- **The key comes back once**, on the settling response. A replayed credential isn't credited twice and gets no second key. An agent that loses the key pays again to get another.
- **One transaction:** the credit and the key commit together, and the org is created beforehand.
- **Both routes go through `Lei.Payments.Gate`.** It refuses by default: anything that isn't an operator JWT and has no org is asked to pay.

The canary asserts that an unauthenticated analysis gets a 402 offering `tempo`.

**What is kept about an anonymous consumer (#149).** Money and counts, never which repositories:

| Kept | Not kept |
|---|---|
| ledger: purchases and debits, with wallet and amount | repository URLs in the request log for wallet orgs (the admin view shows "withheld") |
| `analysis_usage`: monthly hit and miss counts | repository URLs in production logs at `:info` (they're at `:debug` only) |
| the challenge record: amount, org, settled | |

Analysis results are still cached by repository URL. The cache records the repository, not who asked.

### The mode switch, and what guards it (#137)

There is no mode setting. **The mode is whatever `STRIPE_SECRET_KEY`'s prefix
says** (`sk_`/`rk_` + `test_`/`live_`), because only API keys carry a mode --
price IDs, product IDs and `whsec_` secrets look identical in both.

| Fault | Caught | How it shows |
|---|---|---|
| live key outside production | boot | refuses to start; production is `LEI_DEPLOY_ENV = "production"` in `fly.toml` |
| key slot holds `pk_`/`whsec_`/garbage | boot | refuses to start, naming the prefix only |
| webhook slot holds a non-`whsec_` value | boot | refuses to start |
| `STRIPE_PROFILE_ID` from the other mode (`profile_test_` vs `profile_`) | boot | refuses to start |
| price IDs from the other mode | after boot | `/readyz` `checks.stripe = "mismatch"` → degraded |
| price archived | after boot | `checks.stripe = "inactive"` |
| key expired, revoked, or lacks price read | after boot | `checks.stripe = "unauthorized"` |
| Stripe down | after boot | `checks.stripe = "unreachable"`, retried each minute |
| `TEMPO_DEPOSIT_ADDRESS` not in the key's account (e.g. a sandbox address beside a live key) | after boot | `checks.stripe = "mismatch"`, **and no stablecoin challenge is issued**. Mainnet funds sent to a sandbox address are unrecoverable |
| webhook secret from the other endpoint | **no check can** | `lei_stripe_webhook_total{result="invalid"}` on the first delivery |

Price checks run at boot and hourly, and never block boot: a Stripe outage
degrades readiness rather than preventing a start.

The serving mode is `stripe_mode` on `/readyz` and `lei_stripe_mode{mode=...}`
on `/metrics`. The canary asserts it against the repository variable
`STRIPE_EXPECTED_MODE` (defaults to `test` when unset). **Setting that variable
to `live` is part of the cutover** -- until it is, a live key fails the deploy
canary, and afterwards a test key does:

```bash
gh variable set STRIPE_EXPECTED_MODE --body live
```

The deploy canary fails on `mismatch`, `inactive`, `unauthorized` and
`unconfigured`, and rolls back. It tolerates `pending` and `unreachable`, so a
Stripe outage mid-deploy does not roll back a good release; the monitor still
fails on them.

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
  -C "/opt/app/bin/lei_service rpc 'Lei.BillingReporter.report_now()'"
```

Step 5 is the one most likely to be skipped and most likely to be wrong: it is
where a licensed-instead-of-metered price, or a unit mismatch, finally shows up.

### Querying it directly

The Stripe CLI is installed locally. Point it at the right account -- a query
against the wrong one returns an empty list, not an error, which looks exactly
like the meter never received anything.

```bash
stripe config --list          # confirm account_id = acct_1T8rhd36n3SNNomb

stripe get /v1/billing/meters/<METER_ID>/event_summaries \
  -d customer=<CUSTOMER_ID> \
  -d start_time=<hour-aligned unix> \
  -d end_time=<hour-aligned unix>

stripe get /v1/subscriptions -d customer=<CUSTOMER_ID> -d limit=1
```

`start_time` and `end_time` must be hour-aligned or the API rejects them.

Use a **restricted, read-only** key rather than a full `stripe login` for
routine querying. Read access to meters, customers, subscriptions, invoices and
events covers everything above, and cannot refund, modify or delete anything.

## 6. Going live

Nothing from sandbox carries over. Test and live mode hold entirely separate
meters, products, prices, webhook endpoints and signing secrets.

1. Recreate **in live mode**: the `analysis_cost` meter, the product, both prices
   (including the graduated first tier), and the webhook endpoint
2. Replace all five `STRIPE_*` secrets and `TEMPO_DEPOSIT_ADDRESS` **together** in one `flyctl secrets
   import`, and set `STRIPE_EXPECTED_MODE=live`. A half-flip now reads
   `mismatch` on `/readyz` rather than failing at the first customer -- but only
   a delivered webhook proves the signing secret (see section 4)
3. Re-run **all** of section 5 against live keys, with a real card, then refund
4. Watch the first real invoice line by line rather than assuming it matches

The sandbox run found five defects, four of them customer-facing. Treat the live
run as a real test, not a formality.

## ACP self-provisioning

`LEI_ACP_BEARER_TOKEN` and `LEI_ACP_SIGNING_SECRET` are **unset**, and
`Lei.Acp.Auth` skips both the bearer and HMAC checks when they are absent.
`POST /acp/checkout` is therefore open to anyone.

Since 2026-09-15 the only SKU is `lei-credits-29000`: $29 charged once buys
29,000 credits on a prepaid org with no monthly allowance (ADR-002). There is no
free SKU, so an open endpoint provisions nothing without a successful payment.
The former `lei-free` SKU gave any caller a free-tier org, and `lei-pro-monthly`
created an unlimited Pro org from a one-off charge that was never billed again.

Setting either secret turns the corresponding check on.
