# ADR-002: Credit Ledger with Multiple Payment Rails

**Status:** Proposed — core decisions resolved 2026-09-11, amended 2026-09-12 (see
Amendment 1: rails are pluggable, MPP first)
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

> **Superseded by Amendment 1 (2026-09-12).** The reasoning below is sound and
> its conclusion no longer follows: it assumes a chain transaction on the
> request path, which MPP's streaming cadence removes. Settlement granularity
> is now a property of the rail, not a global policy.

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


## Amendment 1 — Two sides, pluggable rails, MPP first

**Date:** 2026-09-12
**Supersedes:** the settlement-granularity decision, the funding-rails decision,
and much of the location problem.

### Why this is being reopened

The original survey predates the **Machine Payments Protocol** (MPP), published
by Stripe and Tempo in March 2026. Choosing x402 without weighing it was a gap
in the research, not a judgement call.

It matters because MPP invalidates the reasoning behind one of the three
"resolved" decisions and dissolves the open question flagged as most dangerous.

### What MPP is

An open standard for machine-to-machine payment over HTTP, using the same 402
status code as x402 and the **same signature substrate** — EIP-3009 and Permit2
for off-chain authorisation. It is not a competing primitive; it is x402's
primitive plus the lifecycle machinery x402 leaves to the implementer: payment
cadence (one-shot, recurring, **streaming**), cancellation, and reconciliation.

The service answers with a payment requirement naming price, accepted methods,
cadence and metadata. Settlement is rail-agnostic: stablecoins on Tempo, cards
and BNPL through Stripe's Shared Payment Tokens, Bitcoin over Lightning.

### What it changes

**Settlement granularity — the reason for blocks is gone.**

The original decision reads: credits are purchased in blocks, because gas is
$0.001–0.005 and a cache hit sells for $0.005, so per-request settlement can
cost more than the thing being sold. That arithmetic was right, and it was
entirely a consequence of putting a chain transaction on the request path.

MPP's model is pre-authorise once, then stream granular usage without a
transaction per interaction. The constraint that forced blocks does not exist
on that rail. Blocks were never desirable in themselves — they were a tax on
the on-ramp and an open question about denomination that nobody wanted to
answer.

**The location problem — largely solved, and not by us.**

The accounting section identified this as the one item that can create liability
retroactively: VAT on digital services depends on where the customer is, a
wallet address says nothing about that, and EU registration can be required from
the first sale. Stripe determines this today and files it; x402 does not.

Under MPP, funds settle into the existing Stripe balance in the default
currency on the normal payout schedule, and the usual Stripe machinery applies
— tax calculation, fraud, reporting, refunds. The thing that made this hard was
building a parallel money path outside the system that already solves it.

This does not make the questions for a qualified accountant go away. It moves
most of them from "we must answer this before selling anything" to "this is
handled the way our existing revenue is handled."

**Security posture.**

x402 now has a body of adversarial analysis: cross-resource substitution via
context-agnostic signatures, a duplicate-settlement race through nonce reuse
under concurrency, allowance overdraft, and denial of settlement. The root cause
named across those papers is bridging synchronous HTTP to asynchronous chain
finality.

Two things worth noting rather than reading as a verdict. Several findings are
SDK and implementation flaws rather than protocol breaks, and MPP shares enough
substrate that it does not automatically escape them. And duplicate-settlement
under concurrency is precisely the class this codebase keeps meeting — the
unique index on `credit_entries.external_ref` is the defence on our side, and
it is already there.

### Decision: two sides, each with pluggable rails

**Neither protocol gets to be the architecture.** The payment construct has two
faces, each a behaviour with adapters behind it:

```
machine side                        human side
  Lei.Payments.MachineRail            Lei.Payments.HumanRail
    requirements/2  -> the 402 body     checkout/2    -> hosted checkout
    verify/2        -> proof accepted   handle_event/1 -> webhook settled
    settlement_ref/1                    settlement_ref/1
      |                                   |
      MPP adapter                         Stripe Billing adapter
      x402 adapter                        (others)
      (others)
               \                       /
                Lei.Credits.grant/4
                reason: "purchase:<rail>"
                external_ref: settlement_ref
```

Both sides terminate in the same ledger. A rail's only privileges are producing
payment requirements, verifying a settlement, and naming it — the naming being
what makes the grant idempotent.

This is the point of the shape rather than a nicety. Every claim in this
amendment is a claim about a market that is roughly six months old and has
already invalidated one of our decisions. The structure that survives being
wrong again is the one where a rail is a module, not a set of assumptions spread
through the request path.

**Decision: MPP is the first machine adapter. x402 is the second.**

MPP first because it removes the accounting blocker that currently prevents
selling anything to anyone, settles into infrastructure already in use, and
does not put a chain transaction on the request path.

x402 second rather than never: it is vendor-neutral (Apache 2.0, x402
Foundation) where MPP settlement runs through Stripe, and it has the larger
installed base — over 100 million transactions on Base through Q1 2026 against
a protocol six months old. An agent that speaks x402 and not MPP is a customer
we would otherwise turn away, and the adapter boundary is what makes serving
both cheap.

**Decision: settlement granularity is a rail's concern, not a global policy.**

Blocks are how a rail behaves when per-request settlement costs more than the
request. They are not a property of the product. MPP streams; x402 sells blocks;
the ledger records credits either way and does not care which arrived how.

### What this does not change

Stages A, B and C stand as built. The append-only ledger, integer credits, the
debit inside the usage transaction, and wallet identity are all rail-agnostic —
`purchase:x402` is a string in a `reason` column, and `purchase:mpp` costs
nothing to add.

One qualification on wallet identity. An org per wallet assumes a crypto-native
customer. MPP's card and Lightning rails mean a paying agent may have no wallet
at all, so `orgs.wallet_address` becomes *one* identity type rather than *the*
identity type for machines. Nothing built so far forbids that — the column is
nullable and the unique index is partial — but the assumption should be named
before more is built on it.

### Availability, which is a real constraint

Stablecoin acceptance through Stripe is available to US businesses except New
York. Outside the US it requires requesting access for 30+ countries. Shared
Payment Tokens are available in all US states. This needs confirming against
where the business is actually established before committing to MPP as the
first adapter.

### What has not been verified

- The MPP specification has been read as documentation and summaries, not
  implemented against. The "few lines of code with PaymentIntents" claim is
  Stripe's, untested here.
- No fee modelling against our actual per-analysis prices. Stripe's stablecoin
  and SPT pricing needs confirming; 2.9% + 30¢ on a $0.005 cache hit would be
  absurd, which strongly implies different terms for machine payments that
  should be read rather than assumed.
- The x402 attack papers have been read via abstracts and summaries. Before
  building the x402 adapter they should be read in full, since several findings
  are about SDK behaviour an implementer inherits.
- Whether Tempo settlement introduces a dependency worth caring about, given
  Stripe offramps to the normal balance automatically.

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

Resolved 2026-09-11: agent identity (org per wallet), agent free tier (none).

Revised by Amendment 1 (2026-09-12): settlement granularity is a rail's concern
rather than a global policy, so block denomination is no longer a blocking
question — it applies to rails that need blocks. The location problem moves
from blocking to handled-as-existing-revenue under MPP, without removing the
need for an accountant.

Remaining:

1. **Do credits expire?** Still no. Revisit when there is redemption history,
   since breakage cannot be estimated without it. Adding expiry later changes
   terms for existing holders.
2. **Where is the business established?** Stripe stablecoin acceptance is US
   except New York, with access outside the US on request for 30+ countries.
   This gates MPP as the first adapter and is a fact to confirm, not a decision
   to make.
3. **Fee structure per rail.** Unmodelled. Standard card pricing against a
   $0.005 cache hit would be absurd, which implies machine payments carry
   different terms — to be read rather than assumed.
4. **Opening balance at migration.** Nearly moot — 36 test orgs, no paying
   customers. Proposal: Pro orgs 15,000 credits, free orgs their remaining
   monthly allowance.
5. **What happens at zero mid-request?** A batch that exhausts the balance
   partway through is either refused entirely, served and allowed to go
   slightly negative, or truncated. Each is defensible; silence is not.
   Currently the balance is checked before the batch and not during it.
6. **Is a wallet still the machine identity?** MPP's card and Lightning rails
   mean a paying agent may have no wallet. `orgs.wallet_address` is nullable
   and its index is partial, so nothing forbids other identity types — but
   what they are has not been decided.

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

Amendment 1:

- Machine Payments Protocol — <https://mpp.dev/>, spec at
  <https://github.com/tempoxyz/mpp-specs>, Stripe's announcement at
  <https://stripe.com/blog/machine-payments-protocol>
- Stripe machine payments docs — <https://docs.stripe.com/payments/machine>
- *Free-Riding the Agentic Web: A Systematic Security Analysis of x402
  Payments* — <https://arxiv.org/abs/2605.30998>
- *Five Attacks on x402 Agentic Payment Protocol* —
  <https://arxiv.org/abs/2605.11781>
- *When HTTP 402 Meets the Blockchain: Risks on Emerging x402 Payments* —
  <https://arxiv.org/abs/2607.19545>


- [ADR-001: Cache-Tiered Pricing Model](001-pricing-model-cache-tiered-analysis.md)
- [docs/BILLING_SETUP.md](../BILLING_SETUP.md) — the verified Stripe path this amends
- [x402 Protocol Adoption Tracker 2026](https://presenc.ai/research/x402-protocol-adoption-tracker-2026)
- [Agentic Payments in 2026: The x402 Explainer](https://www.rzlt.io/blog/agentic-payments-2026-x402-explainer)
- [2026 Comparative Analysis: Agentic Commerce Payment Protocols](https://appliedtechnologyindex.com/research/2026-comparative-analysis-agentic-commerce-payment-protocols/)
- [Agentic Commerce Standards: UCP vs ACP vs AP2 in 2026](https://www.digitalapplied.com/blog/agentic-commerce-standards-ucp-acp-ap2-2026-merchant-guide)
