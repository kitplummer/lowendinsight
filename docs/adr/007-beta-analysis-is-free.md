# ADR-007: Beta — Analysis Is Free, Bounded by the Free Tier

**Status:** Accepted
**Date:** 2026-09-27
**Authors:** Kit Plummer, Claude (AI pair)
**Defers:** ADR-005's three open pricing questions
**Amends:** ADR-001's rates in effect, not the rates themselves

## Context

ADR-001 priced analysis per repository by cache status. ADR-005 proposed
replacing that with positions and left three questions open: where the first
bracket ends, what the subscription costs and includes, and what agents buy.

Those questions are unanswerable at the moment, because the answers depend on
facts nobody has:

- **What the cache is worth.** The whole economic argument in ADR-005 rests on
  deduplication — the five-hundredth customer holding `jason` costing nothing
  extra. The production cache today is 98.7% `low` risk with a median age of one
  week, and it is our own ingestion rather than anyone's dependencies. It is not
  a sample of anything.
- **What an analysis costs to serve at volume.** One customer's manifest of
  hundreds of uncached repositories is the adverse case, and it has never
  happened.
- **What people actually ask for.** Whether requests cluster on popular packages
  (deduplication works) or scatter across private-ish long-tail repositories
  (it does not) decides whether the pricing model in ADR-005 is sound at all.

Each of those is a measurement, and none of them requires anyone to pay.

## Decision

**Analysis is free during beta, bounded by the free tier's allowance.**

`Lei.Billing.mode/0` returns `:charge` or `:beta`. In `:beta`:

- `Credits.cost_in_credits/2` returns 0, so admission requires nothing, debits
  nothing, and `report_meter_event/3` reports nothing to Stripe — it already
  declines to report zero units.
- `UsageTracker.calculate_cost/2` returns 0, so the usage row records that the
  request cost the customer nothing.
- Every org is held to the free tier's allowance, including Pro and
  credit-funded orgs.
- **Usage is still recorded on every request.** That is the point: the cache
  grows, the flows run, and the volume gets measured.

Signup stays open. The payment rails stay enabled, so challenges, settlement and
reconciliation keep being exercised rather than bit-rotting for the length of the
beta.

### Why a mode rather than rates set to zero

Setting `credits_per_cache_miss` to 0 produces identical behaviour and is
indistinguishable from the defect where billing silently stops working. This
repository has shipped "something reports success while broken" nine or more
times; a deployment serving for free is exactly that shape, and the only
difference between the intended version and the defect is that somebody meant
it.

A named mode can be published, and it is: `lei_billing_mode{mode="beta"} 1` on
`/metrics`, with `monitor.yml` asserting the mode it expects. Beta left on after
launch is a red run rather than a month of service nobody billed for.

### Why the default is charging

An unset variable, a typo, a config that failed to load — every one resolves to
`:charge`, in both `Lei.Billing.mode/0` and `runtime.exs`, where only the exact
string `"beta"` enables it.

Free service nobody chose is unnoticed for as long as nobody looks at revenue.
Charging that should not happen is reported by a customer within the hour. The
failure that announces itself is the better default, and
`beta-default-is-free-service` in the mutation manifest is there to keep it that
way.

### Entering and leaving beta is two steps, on purpose

`LEI_BILLING_MODE=beta` on the app, and `LEI_EXPECTED_BILLING_MODE=beta` as a
repository variable. Either alone fails the monitor's check. Leaving beta is the
same in reverse. A single switch would make "we launched and forgot to start
charging" a silent state; two make it a red run.

### Every org, including the ones that pay

A billable Pro org is served without limit under charging, because its usage is
metered to Stripe. In beta nothing is metered, so "unlimited" would mean
unbounded free analysis. Beta's branch therefore comes *before* both the prepaid
and Pro branches in `allowance/3`.

The mirror of that, found by a test rather than by reasoning:
`Wallets.provision/1` and the ACP path both set `free_tier_analyses_limit` to 0
alongside `prepaid: true`, correctly, because a credit-funded org buys analyses
rather than receiving an allowance. Carried into beta unchanged that reads as
"free, and you get none" — every wallet and every agent org refused with
`used: 0, limit: 0`. So in beta a zero limit means "no allowance configured" and
the deployment default applies.

## Consequences

### Positive

- **The measurements ADR-005 needs become possible** without anyone paying for
  the privilege.
- **The flows get exercised.** Signup, analysis, caching, the queue, the payment
  rails and reconciliation all keep running.
- **Existing credit balances are untouched.** The ledger is append-only; nothing
  is spent, nothing expires as a result of this, and the balances are still there
  when charging resumes.
- **The mode is legible.** `/metrics`, `/llms.txt` and `/terms` all state it, and
  all three derive it from the running deployment rather than from prose someone
  remembered to update.

### Negative

- **Revenue is zero during beta.** Deliberate, and the reason for the two-step
  exit.
- **The allowance is the only cost control.** 200 analyses per org per period
  bounds count, not work: one org scanning very large repositories costs more
  than another doing 200 trivial ones. There is a `max_repo_size_kb` guard on
  the analysis path but no per-org concurrency cap, so a determined beta user can
  cost more than the number suggests.
- **An anonymous caller is still asked to pay.** `Gate.admit/2` challenges a
  caller with no org, and beta does not change that: the 402 is an
  authentication boundary rather than a price. The consequence is that an agent
  without an account can buy credits it cannot usefully spend, because analysis
  is free for accounts. Left alone deliberately rather than changed without a
  decision; see Open Questions.
- **Two code paths for charging exist at once**, and only one of them runs in
  production at a time. Mitigated by the beta branch being one `cond` arm and
  one zero, not a parallel implementation.
- **`/terms` is a statement, not a negotiated agreement.** It states that the
  service carries no warranty and that use and reliance are at the consumer's
  own risk, in those terms. Whether that is sufficient for a given jurisdiction
  or customer is not a question this ADR answers.

### Neutral

- ADR-001's rates are unchanged and still published, so nothing about them
  appears from nowhere when beta ends.
- ADR-002's ledger mechanics are untouched.

## Open Questions

1. **Should an anonymous caller be challenged for payment during beta?** Today
   it is, and the credits it buys cannot be spent on anything that is not
   already free. The alternatives are to point it at free signup instead, or to
   accept that the payment rails need exercising and this is how they get it.
   Changing it alters agent-facing behaviour, so it wants a decision rather than
   an implementation.
2. **What ends the beta?** A date, a number of orgs, a volume of analyses, or a
   measurement landing. Nothing currently forces the question, which is how a
   beta becomes permanent.
3. **Does the allowance need a work-based component** — repository size, or
   concurrent analyses per org — rather than a count?

## References

- ADR-001 — the rates, unchanged and still published
- ADR-002 — the ledger; its mechanics are untouched and balances persist
- ADR-005 — the three pricing questions this defers, and the measurements it
  needs that beta produces
- `Lei.Billing`, `Lei.UsageTracker.allowance/3`, `/terms`, `/llms.txt`
- `scripts/mutations.json` — five mutations, including the one that makes an
  unrecognised mode charge rather than serve free
