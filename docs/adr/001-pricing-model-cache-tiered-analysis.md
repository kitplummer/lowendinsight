# ADR-001: Cache-Tiered Pricing Model for LEI Analysis

**Status:** Proposed
**Date:** 2026-03-09
**Authors:** Kit Plummer, Claude (AI pair)
**Supersedes:** N/A

## Context

LEI is an open-source bus-factor risk analysis tool. We are adding a hosted service at `lowendinsight.fly.dev` with payment-gated signup (PR #39). This ADR captures the pricing model decision and the reasoning behind it.

### The Problem

We need a pricing model that:

1. **Sustains the hosted service** — covers Fly.io compute, Postgres, Redis, and the engineering process (Keiro/GLITCHLAB agentic development)
2. **Maximizes agent adoption** — in the vibe-coding era, AI agents are the primary consumers; any friction means agents skip the safety check
3. **Competes honestly with self-hosting** — LEI is BSD-3-Clause open source; anyone can run their own instance; the hosted service must offer clear value over self-run
4. **Scales with actual cost** — not arbitrary seat-based pricing that penalizes growth

### The Shift: From CI Gate to Agent Prevention

The original assumption was CI-centric: analysis runs when lock files change, maybe 5-20 times/month per project. Subscription pricing barely makes sense at that volume.

The real opportunity is **agent-initiated dependency evaluation**. In the agentic and vibe-coded world:

- Agents add dependencies constantly, often without human review
- The evaluation happens **before** dependency selection, not after merge
- An agent asking "should I use library X or Y?" needs instant, cheap risk data
- A single coding session might evaluate 10-50 candidate dependencies
- This is **prevention** (pre-selection) not **detection** (post-merge CI gate)

This changes everything about pricing. The unit of value is not "subscription access" but "risk intelligence at decision time."

### The Self-Hosting Reality

Anyone can clone LEI and run it. The hosted service competes by offering:

- **Shared cache** — the most valuable asset; popular packages already analyzed
- **Zero ops** — no Postgres, Redis, git clone infrastructure to maintain
- **ACP endpoint** — agents self-provision without human setup
- **Ecosystem network effect** — every analysis improves the cache for everyone

The pricing must reflect this honestly. We're selling cache access and operational convenience, not the software itself.

## Decision

### Cache-Tiered Per-Analysis Pricing

Price each analysis based on whether LEI already has a recent result (cache hit) or must perform a fresh git clone and analysis (cache miss).

| Result Type | What Happens | Price | Compute Cost |
|-------------|-------------|-------|-------------|
| **Cache hit** | Lookup in Redis/Postgres, return existing report | **$0.005** | ~$0.00001 |
| **Cache miss** | Git clone → parse history → compute risk scores → cache result | **$0.05** | ~$0.0001–$0.001 |

### Subscription Tiers

| Tier | Monthly | Included | Rate Limit | Overage |
|------|---------|----------|------------|---------|
| **Free** | $0 | 200 analyses/month | 60 req/min | Hard stop |
| **Pro** | $29 | $15 analysis credit (~3,000 cache hits or ~300 misses) | 600 req/min | Cache-tiered rates |

### ACP (Agent) Pay-Per-Use

No subscription required. Agents self-provision via ACP, pay per-analysis at cache-tiered rates. Billed monthly via Stripe metered billing.

### Manifest Scan Pricing

A manifest/lock-file scan (e.g., `package-lock.json` with 1,200 transitive deps) is priced as the **sum of individual dependency costs**:

```
React project: 1,200 transitive deps
  1,100 cache hits  × $0.005 = $5.50
    100 cache misses × $0.05  = $5.00
  Total: $10.50

Niche Rust tool: 80 transitive deps
  20 cache hits  × $0.005 = $0.10
  60 cache misses × $0.05  = $3.00
  Total: $3.10
```

This is transparent and self-correcting: as a package becomes popular in the ecosystem, its analysis gets cached, and everyone's costs go down.

## Rationale

### Why Not Flat Per-Analysis ($0.10)?

We considered a flat $0.10 per dependency regardless of cache status. Problems:

- A manifest scan with 1,500 transitive deps = **$150**. This kills adoption for the highest-value use case (full project audits).
- It doesn't reflect actual cost. A cache hit costs essentially nothing to serve.
- It creates perverse incentives: users avoid scanning large projects, which are the ones that need it most.

### Why Not Pure Subscription?

- **Agent adoption friction**: Agents need to evaluate LEI before their operators commit to a subscription. Pay-per-use via ACP is the natural on-ramp.
- **Usage variance**: A solo developer and a 50-person team have radically different volumes. Per-seat or flat subscription either overcharges small users or undercharges large ones.
- **Self-hosting arbitrage**: If the subscription is too expensive for the volume, users just self-host. Cache-tiered pricing keeps the hosted service competitive because the cache value increases with the ecosystem.

### Why Cache-Tiered Specifically?

1. **Honest cost reflection** — cache hits cost ~$0.00001 to serve; cache misses cost ~$0.001 in compute + bandwidth. The 10x price gap reflects the 100x cost gap.

2. **Ecosystem flywheel** — every analysis improves the shared cache. As adoption grows, the cache hit rate rises, the average cost per analysis drops, which drives more adoption. This is a positive feedback loop that self-hosting cannot replicate.

3. **Agent-aligned incentives** — agents that pick well-known, well-maintained dependencies (which tend to be cached) pay less. This economically aligns with the security outcome we want: prefer established, actively-maintained packages.

4. **Transparent to consumers** — the API response includes `cache_status` already. Adding `cost_cents` makes the economics visible. Agents can reason about cost/benefit. No surprise bills.

5. **Self-hosting remains viable** — organizations with high volume or air-gapped requirements can still run their own LEI instance. The hosted service wins on cache breadth and zero ops, not artificial lock-in.

### Why $0.005 / $0.05?

**Cache hit ($0.005):**
- Floor: ~$0.00001 compute cost → 500x margin
- At this price, 200 cache hits = $1.00. An agent evaluating 20 cached dependencies per session = $0.10. Invisible next to LLM API costs ($5-20/session).
- Low enough that no agent operator would skip the safety check to save money.

**Cache miss ($0.05):**
- Floor: ~$0.001 compute cost (git clone + analysis) → 50x margin
- Accounts for: Fly.io compute (5-30 sec), bandwidth for git clone, Postgres/Redis write, cache warming that benefits future users.
- The user who triggers the first analysis of a rare package pays a premium; everyone after them gets the cached price. This is fair: they're funding the cache for the ecosystem.

**Margin covers fixed costs:**
- Fly.io infrastructure: ~$30-50/month
- Postgres + Redis: ~$10-20/month
- Engineering process (Keiro/GLITCHLAB): ~$50-200/month
- Total fixed: ~$100-300/month

Break-even at modest scale:
- 10 Pro subscriptions: $290/month
- 5,000 ACP agent queries (80% cache hit): ~$45/month
- 50 manifest scans: ~$200-500/month
- Total: ~$535-835/month

### Competitive Positioning

| Competitor | Model | LEI Advantage |
|-----------|-------|---------------|
| **Socket.dev** | Freemium SaaS, proprietary | LEI is open-source; self-hosting is always an option |
| **Snyk** | Per-developer seat ($25-50/dev/mo) | LEI charges for actual usage, not headcount |
| **OpenSSF Scorecard** | Free (no hosted API with SLA) | LEI offers managed service with cache + ACP |
| **Self-hosted LEI** | Free (your own infra) | Hosted LEI offers shared cache + zero ops |

The cache is the moat. A self-hosted instance starts with an empty cache. The hosted service has the entire ecosystem's analysis history.

## Implementation

### Stripe Products

1. **LEI Pro** — $29/month recurring subscription
2. **LEI Analysis** — metered price, usage reported at billing cycle end as total `cost_cents`

### API Response Addition

```json
{
  "data": { "...risk report..." },
  "cache_status": "hit",
  "cost_cents": 0.5,
  "cache_ttl_remaining_hours": 672
}
```

### Usage Tracking

- Per-org counter in Postgres: `analysis_usage` table (org_id, period_start, cache_hits, cache_misses, total_cost_cents)
- Increment on each `/v1/analyze` call
- Report to Stripe via `Stripe.UsageRecord` at billing cycle end
- Pro tier: deduct included credit before reporting overage

### Free Tier Enforcement

- 200 analyses/month hard cap (tracked in `analysis_usage`)
- Return 402 with upgrade prompt when exceeded
- Rate limit remains at 60 req/min

### Cache TTL

- Default: 30 days (configurable via `LEI_CACHE_TTL`)
- After TTL expiry, next analysis is a cache miss (re-clones, re-analyzes)
- Consumers can see `cache_ttl_remaining_hours` in the response to understand freshness

## Consequences

### Positive

- Agents adopt LEI with zero friction (free tier + ACP pay-per-use)
- Pricing is transparent and predictable — consumers can estimate costs before calling
- Ecosystem flywheel: more users → better cache → lower costs → more users
- No artificial lock-in; self-hosting remains a first-class option
- Revenue scales linearly with actual usage and value delivered

### Negative

- Revenue per analysis decreases as cache hit rate improves (good for users, requires volume growth to compensate)
- Metered billing adds implementation complexity (usage tracking, Stripe reporting)
- Must monitor cache hit rates to ensure margin remains healthy
- Large manifest scans could produce unexpectedly high bills for projects with many novel/niche dependencies (mitigated by transparent per-dep cost in response)

### Risks

- **Race to zero**: If a competitor offers free cached analysis, our cache hit revenue evaporates. Mitigation: the shared cache is a network effect; hard to replicate without the user base.
- **Cache poisoning**: Bad data in cache affects all consumers. Mitigation: cache TTL forces periodic re-analysis; anomaly detection on risk score changes.
- **Self-hosting leakage**: Large organizations may self-host and backfill their own cache from our API. Mitigation: this is fine — the hosted service wins on convenience and breadth, not data hoarding.

## Open Questions

1. Should we offer a "cache warming" product? Organizations pay to pre-populate analysis for their dependency tree, ensuring all their deps are cache hits going forward.
2. Should cache miss pricing vary by repo size? A monorepo clone costs significantly more than a small library.
3. What's the right free tier cap — 200/month enough for a solo vibe-coder's agent?
4. Should we publish cache hit rates as a public metric to build trust in the pricing model?

## References

- [PR #39: Payment-gated signup, ACP, key recovery](https://github.com/kitplummer/lowendinsight/pull/39)
- [Vibe Coding Integration Research](../apps/lowendinsight/docs/VIBE_CODING_INTEGRATION.md)
- [Stripe Metered Billing](https://docs.stripe.com/billing/subscriptions/usage-based)
- [ACP — Agentic Commerce Protocol](https://openai.com/index/agentic-commerce-protocol/)
