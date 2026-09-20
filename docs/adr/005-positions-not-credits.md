# ADR-005: Positions, Not Credits

**Status:** Proposed
**Date:** 2026-09-20
**Authors:** Kit Plummer, Claude (AI pair)
**Supersedes:** ADR-001 (pricing model)
**Amends:** ADR-002 (the credit ledger's purpose, not its mechanics)

## Context

ADR-001 priced each analysis by whether we had it cached: $0.005 for a hit,
$0.05 for a miss, summed across a manifest. Six months of building against that
model surfaced four problems, three of them measured rather than argued.

### The $0.50 floor is real, and credits are its residue

Stripe refuses payments under $0.50. Tested directly against a plain crypto
PaymentIntent and a `transaction_verification` PaymentIntent on the
`2026-07-29.preview` API:

```
"code": "amount_too_small",
"message": "Amount must be no less than $0.50 usd"
```

The MPP documentation's claimed "0.01 USDC minimum" does not hold.
`tempo.ex:38`'s `@minimum_cents 50` was right.

So a $0.005 cache hit cannot be a transaction. It is 1/100th of the smallest
thing our payment rails can move. **Prepaid credits exist to aggregate charges
beneath a payments constraint** — they are not a product decision, and every
downstream question they create (deferred revenue, breakage, expiry, ADR-002's
first accounting question) is a consequence of pricing below the floor.

### Cache status is our cost, not the buyer's value

It is wrong at both ends. A cached answer can be exactly what a buyer needs,
delivered instantly, and we charge a tenth. A fresh analysis of an abandoned
repository costs us a clone and tells them something they could have guessed.

The price tracked our expense and called it value. Worse, the buyer cannot
predict it: it depends on our internal state, which they cannot see and did not
cause.

### Dependency trees move far more than assumed

Measured against this repository's own 62-dependency tree — the first corpus we
have that resembles what customers ask about:

| window | moved (any commit) | moved (substantive only) |
|---|---|---|
| 1 week | 26% | 21% |
| 1 month | **44%** | 39% |
| 3 months | 59% | 57% |
| 6 months | 72% | 69% |

**Forty-four percent of a dependency tree moves every month.** For a
1,500-package tree that is ~660 packages needing re-analysis monthly.

Two things follow. A model that bills per re-analysis raises the customer's
bill because *other people committed code* — for reasons they did not cause and
cannot control. And substantive-only invalidation (#244) saves 11% here, not
the large figure assumed when the mechanism was designed; the gap is likely
wider on npm trees under Dependabot, but that is unmeasured.

### The model can charge for nothing

#255: an analysis that could not clone returned `{:ok, report}` with every
metric `nil`, was cached for thirty days, and cost the requester a cache miss —
$0.05 for an answer containing nothing, then $0.005 per subsequent request.
Fixed in #256, and the refund remains open as #258.

That was possible because the unit of sale was **the attempt**, not the answer.

## Decision

Sell **positions**. A position is an answer a customer holds about a package:

```
(org, package, resolved commit)
```

Two lines of revenue, each mapping to a real cost:

| | what it buys | charged |
|---|---|---|
| **Open a position** | the answer for a package the customer does not already hold | once, bracket-priced |
| **Hold a position** | keeping that answer current, and being told when its risk changes | subscription |

### Opening a position

Priced in brackets over the count of *new* positions in a request. Every
bracket clears $0.50 by construction, so no charge is ever below what the
payment rails can move.

The ladder is not fixed by this ADR (see Open Questions), but must be
**concave** — price per package falling as the bracket rises — so that
splitting a request is never cheaper than bundling it. That property makes the
pricing ungameable and points the incentive at fewer, larger requests, which is
also what costs us least.

### Holding a position

A subscription. Refreshes come out of it, because *we* decide when to refresh:
the customer asked once and expects the answer to stay true. Upstream churn is
our operational problem, not a line on their invoice.

This is affordable because watching deduplicates. The five-hundredth customer
holding `jason` costs nothing extra to watch — we are already watching it. The
shared cache ADR-001 identified as the core asset becomes the margin rather
than a discount we hand back.

### What goes away

- **Cache-tiered pricing.** The price no longer depends on our internal state.
- **Credits as a customer-facing unit.** Nothing is priced below $0.50, so
  there is nothing to aggregate.
- **The validity window question.** "How long is an answer good for" stops
  being a contract term and becomes an operational target, because the
  subscription already commits us to keeping it current.

## Rationale

### The bill becomes predictable from the customer's own records

Under cache-tiered pricing a customer could not forecast a scan: the price
depended on what we happened to hold. Under positions they can. They know which
packages they already hold, and *upstream movement is a public fact they can
verify themselves* — `git ls-remote <url> HEAD` against the SHA they hold,
costing nothing and needing no account.

That is the difference between a price and a surprise.

### Charging for answers makes #255 unrepresentable

A failed analysis yields no position, so there is nothing to charge for. The
defect is not fixed, it is removed from the space of possible states — the same
move as making an unbilled Pro org unrepresentable rather than detectable.

#258's refund logic becomes unnecessary rather than implemented.

### Staleness is knowable, not guessable

An analysis is stale if and only if the upstream HEAD moved. We already store
`data.git.hash` and `data.git.last_commit_date` on every report, and
`ls-remote` answers in tens of milliseconds without a clone, a token, or a
host-specific API.

A cost cascade follows, each layer only paying for the next when it must:

```
ls-remote            ~free      did anything move?
compare (one call)   cheap      did anything meaningful move?   (#244)
full clone           real cost  re-analyse
```

### Freshness is the value, and it is the leading indicator

A CVE feed reports that something has already gone wrong. This estimates
whether anyone will be there when it does. That is worth a subscription in a
way that a one-off scan is not: the decision to take a dependency is made once,
but it does not stay correct, and nothing else a customer owns is watching
somebody else's repository on their behalf.

## Consequences

### Positive

- No charge below the payment floor, so no credits, no deferred revenue, no
  breakage, no expiry policy, and ADR-002's first accounting question dissolves
  rather than being answered
- The customer can predict and audit their bill without access to our systems
- Revenue recognition is immediate for position opens; the subscription is an
  ordinary monthly service
- Billing for a non-answer becomes structurally impossible
- Upstream churn stops being visible on the customer's invoice

### Negative

- **The subscription must carry refresh cost.** At 44% monthly churn, a
  1,500-position holder implies ~660 re-analyses a month. Dedupe makes this
  affordable across customers, but a single customer holding a large private
  tree with no overlap is the adverse case, and it is not modelled.
- **We now carry churn risk.** Under per-analysis pricing, upstream activity
  raised revenue; now it raises cost.
- **The ACP `lei-credits-29000` SKU and the credit ledger have live code behind
  them.** This is not a config change. `Lei.Credits`, `Lei.Payments.Gate`, the
  usage tracker and the ACP flow all assume credits.
- **Existing customers, if any, are on the old model** when this lands.

### Risks

- **The churn figure comes from one tree, in one ecosystem.** 62 Elixir
  dependencies is better evidence than the production cache (98.7% `low`,
  median age one week — our own ingestion, not anyone's dependencies), but it is
  not a sample of anything. An npm tree would likely churn harder.
- **Position counts could grow faster than subscription revenue** if customers
  hold large trees on entry-level plans. The subscription needs a position
  allowance, which is a pricing decision not yet made.
- **Self-hosting pressure increases** if the subscription is the main line: a
  customer who only wants one scan has less reason to stay.

## Open Questions

1. **Where does the first bracket end?** Everything above $0.50 clears the
   floor, but whether a 20-package project pays $0.50 or $1.50 decides whether
   the hobby case is served at all.
2. **What does the subscription cost, and what position allowance does it
   include?** This is now the number the business runs on. `$29/mo` Pro exists;
   whether it becomes "hold up to N positions" is undecided.
3. **What do agents buy?** ACP sells `lei-credits-29000` today. Under positions
   there are no credits. A position bundle is the obvious analogue, but agents
   pay per interaction and may not have a durable identity to hold positions
   against. Per ADR-002 and existing practice, an agent purchase credits the
   ledger and never sets `tier: pro`; whatever replaces it must preserve that.
4. **Does a position survive a package moving hosts or being renamed?** The
   cache key is derived from the URL, so today it would not.

## References

- ADR-001 — the cache-tiered model this supersedes
- ADR-002 — the credit ledger; its mechanics stand, its purpose narrows
- #242, #244, #246, #247 — the risk model this prices
- #255, #256, #258 — charging for a non-answer
- #250 — dependency risk measured on ourselves, which is the argument for the
  product
