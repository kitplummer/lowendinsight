# ADR-002: Credit Ledger with Multiple Payment Rails

**Status:** Proposed — core decisions resolved 2026-09-11, accounting open
**Date:** 2026-09-11
**Authors:** Kit Plummer, Claude (AI pair)
**Amends:** ADR-001 (cache-tiered pricing) — the rates stand; the settlement mechanism changes

## Context

ADR-001 priced analysis per-call with cache tiering and said agents would be
"billed monthly via Stripe metered billing". Building that revealed the
assumption underneath it does not hold.

### Money only exists as Stripe state

There is no internal representation of what a customer has paid for. An org's
entitlement is inferred from `tier`, `status`, and the presence of
`stripe_customer_id`. Consumption is recorded in `analysis_usage` but nothing
debits anything.

The consequence is that any funding path which is not a Stripe *subscription*
silently falls out of billing. Concretely, discovered 2026-09-11:

`Lei.Acp.finalize_paid_session/2` charges a one-off payment intent and creates
the org as `tier: "pro"`. It never sets `stripe_customer_id`, so
`UsageTracker.report_meter_event/3` skips it. And `check_analyze_quota/1`
returns `{:ok, :pro}` for pro-tier orgs, bypassing the free-tier cap.

**An agent pays $29 once through ACP and then gets unlimited analysis, forever,
never billed again.** Nothing in the system notices.

That is not a wiring bug to patch. It is what happens when entitlement has no
representation of its own: every new payment rail has to re-implement billing,
and any one that forgets fails silently.

### Two customers, two payment shapes

We want both, and they do not fit one mechanism:

| | Organisations | Agents |
|---|---|---|
| Onboarding | signs up, adds a card | no account, no human |
| Commitment | monthly subscription | none |
| Payment | postpaid, invoiced | prepaid, per-transaction |
| Failure mode | invoice unpaid | insufficient funds |

A subscription cannot express "this agent wants $2 of analysis and has no
account". Per-request settlement cannot express "invoice this company monthly".

### x402 fits unusually well

x402 (Coinbase, with Cloudflare, Stripe, Visa and Circle) settles API calls in
stablecoin over HTTP: the server answers `402 Payment Required` with payment
requirements, the agent pays and retries with proof.

**LEI already answers 402.** `/v1/analyze` returns
`{"error": "free_tier_quota_exceeded", ...}` with that status today, and the
billable unit is already a priced API call. The impedance match is close, which
is not true of most businesses adding agent payments.

The caveat is commercial, not technical: by April 2026 x402 had ~167M settled
transactions across ~69,000 agents, but roughly half is testing and real volume
is around $28K/day **across the entire network**. Supporting it is a positioning
bet, not a revenue forecast.

## Decision

**Introduce a credit ledger as the single settlement primitive. Every payment
rail funds credits; every analysis debits them.**

### The unit

**1 credit = $0.001** (a tenth of a cent), the same unit already chosen for the
Stripe meter in #88.

| | Credits |
|---|---|
| Cache hit ($0.005) | 5 |
| Cache miss ($0.05) | 50 |
| Pro monthly grant ($15) | 15,000 |
| Free tier monthly grant | 1,000 (≈200 hits, matching ADR-001's cap) |

Every ADR-001 rate is an integer in this unit. Cents would make a cache hit 0.5.

### Append-only ledger

```
credit_entries
  id, org_id, delta (integer credits, signed),
  reason ("grant:subscription" | "purchase:stripe" | "purchase:x402" |
          "debit:analysis" | "adjustment:manual" | "expiry"),
  external_ref (stripe payment intent, x402 tx hash, ...),
  usd_value_cents (nullable; USD value at receipt, grants only),
  jurisdiction (nullable; whatever location signal was obtainable),
  metadata, inserted_at
```

`usd_value_cents` and `jurisdiction` exist for the accounting requirements below
and are null on debits.

Balance is the sum of deltas. **Not a mutable balance column** — money needs an
audit trail, and "how did this balance get here" must be answerable without
guessing. A materialised balance may be added later as a cache, reconciled
against the sum.

`external_ref` is **unique where present**. That is the idempotency boundary: a
replayed Stripe webhook or a resubmitted x402 payment proof cannot double-credit.

### Agent identity: an org per wallet

An x402 agent has no signup, no email and no organisation. Its only durable
identifier is **the wallet address that paid**.

**Decision: create an org whose identity is a wallet address.**

The alternative — keying credits to an address with no org row — is conceptually
cleaner but means a parallel data model: every existing table, every usage
record, the rate limiter and all reporting assume `org_id`. An org row with a
wallet address preserves all of it.

The cost is conceptual honesty: there will be `orgs` rows that are not
organisations. That is an acceptable price for not maintaining two identity
systems, and the column name says what it is.

```
orgs.wallet_address  text, unique where present
```

### Funding rails

| Rail | Grants credits when |
|---|---|
| Stripe subscription | invoice paid → monthly grant (15,000 for Pro) |
| Stripe one-off / ACP | payment intent succeeds → credits proportional to amount |
| **x402** | payment proof verified on-chain → credits for that request |
| Free tier | scheduled monthly grant -- **web signups only, see below** |
| Manual | support adjustments, with a reason |

### No free tier for agents

**Decision: agents fund a block before their first request. The free tier is for
humans evaluating the product.**

A monthly free credit grant is farmable. ACP self-provisioning is open by
design, so an agent can create orgs cheaply and harvest a grant from each.
Rate limiting (#95) slows that to roughly 7,200 orgs/day; it does not stop it.

The current quota has the same hole. Nobody exploited it because ACP did not
work until this week.

Splitting by provenance removes the vector entirely and matches how the two
audiences behave: a human needs to try before buying, while an agent is already
spending someone's budget. It does mean an agent cannot sample before paying,
which is a deliberate trade.

### Settlement granularity: blocks, not per-request

**Decision: credits are purchased in blocks.**

This is forced by economics rather than preference. A USDC transfer on Base
costs roughly $0.001-0.005 in gas. A cache hit is **$0.005**. Settling each call
on-chain would spend between 20% and 100% of the transaction value on the
transaction itself. For a cache miss ($0.05) it is 2-10%, tolerable but poor.

So the 402 challenge says "buy credits", not "pay for this call". It is still
x402 -- the protocol does not require one payment per request -- but the unit
being sold is a balance.

This also strengthens the case for the ledger: without a balance to draw
against, calls priced at half a cent cannot be settled on-chain at all.

### Overage: per-org policy, not global

Orgs with a payment method on file may go negative and be invoiced — that is
what "sign up and consume" means. Agents paying per transaction must not.

```
orgs.allow_overage  boolean, default false
```

- `true` (subscription orgs): balance may go negative; the shortfall is reported
  to Stripe as metered usage, exactly as today
- `false` (prepaid, x402, ACP): a request that would take the balance below zero
  returns **402** with the amount required

The existing Stripe metering path is preserved rather than replaced. It becomes
the settlement mechanism *for overage on postpaid orgs*, instead of the only
mechanism that exists.

### Usage records stay

`analysis_usage` continues to record what was consumed. Credits record what was
paid. They are reconciled, not merged: one is operational, the other financial,
and conflating them is how the current design lost track of ACP payments.

## Accounting and tax

**This section states the shape of the problem and what the ledger must capture.
It is not tax advice, and several items below need a qualified accountant before
credits are sold to anyone.**

### Selling credits is not earning revenue

Under ASC 606 and IFRS 15, payment received before the service is delivered is a
**contract liability**, not income. Revenue is recognised as credits are
consumed.

The append-only ledger gives this directly, which is a reason to prefer it over
a balance column beyond auditability:

```
sum(grants)            = liability incurred
sum(debits)            = revenue recognised
sum(all deltas)        = deferred revenue outstanding
```

A mutable balance can tell you what is owed. It cannot tell you what was earned,
or when.

### Breakage

Credits sold and never consumed are **breakage**. Under ASC 606 it may be
recognised proportionally as the rest is consumed *if* non-redemption can be
reliably estimated, and otherwise only when redemption becomes remote.

With no history, no reliable estimate exists, so breakage is recognised late or
not at all. That argues for the no-expiry decision being revisited once there is
data -- not for adding an expiry now to manufacture a recognition event.

### The location problem

This is the sharpest issue and it is created by the wallet-as-identity decision.

VAT on digital services depends on **where the customer is**. A stablecoin
payment follows the normal VAT rules for the underlying service -- the crypto
leg itself is exempt as currency exchange (CJEU, *Hedqvist* C-264/14) but the
service is not. EU cross-border B2C digital services can require One-Stop Shop
registration, and for some digital-service categories from the **first sale**,
with no threshold.

**A wallet address tells us nothing about jurisdiction.** Stripe determines this
today and handles the filing; x402 does not.

Three directions, none free:

| | |
|---|---|
| **Merchant of record** | An MoR takes on the tax liability and filing, at a percentage. Removes the problem rather than solving it. |
| **Collect a declaration** | Require the buyer to state jurisdiction. Cheap, and weak evidence if audited. |
| **Restrict availability** | Sell x402 credits only where the obligation is manageable. Narrows the market deliberately. |

This needs deciding **before** credits are sold, not after. It is the one item
here that can create a liability retroactively.

### Receiving USDC

USD value must be recorded **at the moment of receipt**, not at conversion. For
a dollar-pegged stablecoin the spread is small but not always zero, and holding
rather than converting can create a basis to track.

The ledger therefore records, on every grant:

```
usd_value_cents      integer   -- value at receipt, not credit face value
external_ref         text      -- tx hash or payment intent, unique
jurisdiction         text      -- nullable; whatever signal was obtainable
```

`usd_value_cents` and the credit face value are usually equal and occasionally
are not. Storing only one of them makes the difference unrecoverable.

### For a qualified accountant

1. Is the taxable supply the **sale** of credits or their **redemption**?
2. What VAT/GST registration does selling to unidentified international buyers
   create, and does a merchant of record change the answer?
3. Is a jurisdiction declaration from the buyer sufficient evidence?
4. What breakage policy is defensible with no redemption history?
5. Does holding USDC rather than converting on receipt create reporting we do
   not want?
6. At what volume do money-transmission or AML obligations begin?

## Rationale

**Why a ledger rather than fixing the ACP path.** Patching
`finalize_paid_session` to create a Stripe customer would fix that one rail and
leave the next one to rediscover the same hole. The defect is structural: there
is no place for "this customer has paid for N units of work" to live, so each
rail invents its own and one of them forgot.

**Why append-only.** Balance-as-a-column makes "the number is wrong" unanswerable.
With money, and especially with irreversible on-chain settlement, the ability to
replay how a balance was reached is worth more than the read performance.

**Why prepaid by default.** An unauthenticated agent with no account cannot be
invoiced, and cannot be pursued for a debt. The only safe default is that it
cannot consume what it has not paid for. Orgs opt into postpaid by supplying a
payment method, which is exactly the trust that justifies it.

**Why keep Stripe metered billing.** It works and is verified in production
(`aggregated_value: 200.0`, confirmed 2026-09-11). Replacing a working, tested
billing path to satisfy architectural tidiness would be a poor trade. Under this
ADR it narrows to postpaid overage, which is the case it genuinely suits.

**Why the same unit as the meter.** The conversion already exists and is proven
end to end. A second unit would mean a second conversion, and conversions between
money units are where rounding errors become revenue errors.

## Consequences

### Positive

- One accounting path. A new rail funds credits and inherits metering, quota
  enforcement and reporting without touching the analysis path.
- ACP's silent gap closes as a side effect rather than a special case.
- Prepaid agents cannot consume what they have not paid for, by construction.
- "Why is this balance what it is" is answerable from the ledger.

### Negative

- A new table, a new invariant, and a debit on the analysis hot path.
- Credits sold and unconsumed are **deferred revenue** — a real accounting
  liability, not just a number in a database. Expiry policy becomes a question
  with tax consequences.
- Two settlement modes (prepaid, postpaid) is genuinely more complex than one.
  Justified only because the two customer shapes genuinely differ.

### Risks

- **Double-spend on debit.** Concurrent requests could each see sufficient
  balance. Requires a transaction with appropriate isolation, or a reservation
  step. This is the implementation's main correctness risk.
- **On-chain settlement is irreversible.** A Stripe payment can be refunded; a
  USDC transfer cannot. Credit grants from x402 must be verified before granting,
  never optimistically.
- **Verification dependency.** Verifying payments on-chain ourselves means
  running or trusting infrastructure. Using a facilitator (Coinbase's, say) means
  a third party in the settlement path.
- **Migration.** Existing orgs have usage but no ledger. Their opening balance
  has to be derived, and the derivation has to be defensible.

## Open questions

Resolved 2026-09-11: agent identity (org per wallet), agent free tier (none),
settlement granularity (blocks). Network and asset default to USDC on Base, the
x402 default; verification via a facilitator rather than self-hosted, since
running it means an RPC dependency, reorg handling and a confirmation policy
that are not where the value is.

Remaining:

1. **Do credits expire?** Decided *no* for now. Revisit when there is redemption
   history, since breakage cannot be estimated without it. Note that adding
   expiry later changes terms for existing holders.
2. **The location problem above.** Merchant of record, buyer declaration, or
   restricted availability. Must be settled before credits are sold.
3. **Opening balance at migration.** Nearly moot -- 36 test orgs, no paying
   customers. Proposal: Pro orgs 15,000 credits, free orgs their remaining
   monthly allowance.
4. **Block sizes.** What denominations does an agent buy? Too small and gas
   dominates again; too large and the on-ramp has a high first step.
5. **What happens at zero mid-request?** A batch that exhausts the balance
   partway through is either refused entirely, served and allowed to go slightly
   negative, or truncated. Each is defensible; silence is not.

## Implementation sketch

Deliberately not a plan. Order reflects dependency, not commitment.

1. `credit_entries` table and a `Lei.Credits` context — balance, grant, debit,
   with idempotency on `external_ref`
2. Debit on the analysis path, behind a flag, running alongside existing quota
   enforcement until the two agree
3. Stripe rails grant credits: subscription invoice paid, one-off payment
   succeeded
4. `allow_overage` replaces the tier check in `check_analyze_quota/1`
5. x402: 402 challenge with payment requirements, proof verification, credit
   grant on the retried request
6. Remove the tier-based quota path once credits have been authoritative for a
   full billing period

Steps 1–4 close the ACP gap and are useful without x402. Step 5 is the
positioning bet and can be deferred without stranding anything.

## References

- [ADR-001: Cache-Tiered Pricing Model](001-pricing-model-cache-tiered-analysis.md)
- [docs/BILLING_SETUP.md](../BILLING_SETUP.md) — the verified Stripe path this amends
- [x402 Protocol Adoption Tracker 2026](https://presenc.ai/research/x402-protocol-adoption-tracker-2026)
- [Agentic Payments in 2026: The x402 Explainer](https://www.rzlt.io/blog/agentic-payments-2026-x402-explainer)
- [2026 Comparative Analysis: Agentic Commerce Payment Protocols](https://appliedtechnologyindex.com/research/2026-comparative-analysis-agentic-commerce-payment-protocols/)
- [Agentic Commerce Standards: UCP vs ACP vs AP2 in 2026](https://www.digitalapplied.com/blog/agentic-commerce-standards-ucp-acp-ap2-2026-merchant-guide)
