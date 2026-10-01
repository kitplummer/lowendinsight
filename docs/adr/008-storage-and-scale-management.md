# ADR-008: Storage and Scale Management

**Status:** Proposed
**Date:** 2026-09-29
**Authors:** Kit Plummer, Claude (AI pair)
**Relates to:** ADR-004 (background work), ADR-005 (positions, and the shared
cache as the asset)

Measured quantities — per-report and per-analysis cost, corpus sizing, and the
limits this refers to — are operating figures and live outside this repository.
This ADR states the shape of the problem and the options; it deliberately does
not carry the numbers.

## Context

Corpus build-up is paused. Before it resumes, three things need deciding
together, because each one's answer changes the others: where reports live, what
bounds a single job, and what the cache does when it cannot grow.

Everything below is measured unless it says otherwise.

### What a report costs to keep

A stored report is small — single-digit to low tens of kilobytes, with a tail
into the hundreds. Whole-corpus sizing, and what filling one costs, are operating
questions and are recorded outside this repository; the shape that matters here
is that **payload size is not the constraint**. A corpus of any size we would
plausibly hold is a fraction of a gigabyte of JSON.

The constraint is entirely where those bytes sit, and what happens when that
place is full.

### Reports live in Redis, which has a budget and evicts them

**Corrected 2026-09-29.** The first version of this ADR described production from
`apps/lei_service/docs/OPERATIONS.md`:

```
maxmemory:        unlimited (default)
maxmemory_policy: noeviction
```

and reasoned from it that no eviction is right, that a large job cannot push
another customer's entries out, and that the shared corpus is not a
noisy-neighbour lottery. **Every part of that was wrong about production.**

The memory metric added after this ADR was written read production on its first
scrape:

```
lei_redis_maxmemory_bytes 1073741824
lei_redis_maxmemory_policy{policy="optimistic-volatile"} 1
```

A budget of 1 GiB, and a **volatile eviction policy** — one that evicts keys
carrying a TTL when memory is tight. Every report is written with `SETEX`
(`datastore.ex:145`), so **every report we hold is evictable**. The operations
note appears to describe a Redis run locally, not the one production uses.

So the shared corpus already *is* the lottery the ADR said it was not. A large
job that fills memory does not refuse its own writes; it silently evicts entries
belonging to whoever else is in there. Nobody decided that. It arrived with the
provider's default.

Three things follow, and they change the questions rather than just the facts:

**There is a ceiling, and it is close.** 1 GiB is the budget, not an abstraction.

**The failure mode is eviction, not refusal.** Refused writes would at least be
loud at the write site. Silent eviction is invisible from both ends: the evicted
customer's next request is a cache miss that looks like an ordinary miss, and the
evicting job succeeds. There is nothing to notice.

**Production is holding almost nothing.** Used memory at the same scrape was
**7,490 bytes**. Whatever the corpus is assumed to be elsewhere, today it is
empty, so none of the above is presently biting — and any reasoning about corpus
composition needs rechecking against a measurement rather than against an
earlier document.

### What bounds a large job today

| bound | value | where |
|---|---|---|
| analysis queue concurrency | 5 | `config/prod.exs` (`OBAN_ANALYSIS_CONCURRENCY`) |
| trending concurrency | 1 | `config/prod.exs` — a second concurrent trending analysis exhausted the machine's memory (#158) |
| repositories per request | **none** | bounded only by the org's remaining quota |
| individual repository size | `max_repo_size_kb` | customer path |
| SBOM request timeout | 60 s default | `sbom_timeout` |

The gap is the third row. A manifest scan is bounded by what the org may spend,
not by what the machine can hold. In beta the free-tier allowance is the only
thing standing between us and a 3,580-package manifest — `immich-app/immich` has
exactly that many. **Quota is a billing control being used as a capacity
control**, and once billing is on, a funded org can submit ten thousand
repositories in one call.

Disk during a job is concurrency times per-clone, and the per-clone distribution
has a long tail: a median in the low megabytes and a maximum in the hundreds. At
the configured concurrency a few unlucky draws is gigabytes.

### The cache is both the relief and the pressure

A large job is affordable *because* of the cache — under ADR-005's model the
customer pays for misses, and the fiftieth manifest scanned mostly hits. The same
job is also what fills memory fastest. The mechanism that makes large jobs cheap
is the one they exhaust.

And today the cache actively discards work it could keep. The 30-day TTL deletes
entries whether or not the repository changed — but an unchanged repository's
analysis stays correct indefinitely: five of six risk metrics are pure functions
of the cloned history, and the sixth is clock-relative and already recomputed on
read by `Lei.ReportFreshness` from the stored `last_commit_date`. So expiry
buys nothing in correctness and costs a re-clone plus, under ADR-001, a miss
price for an answer we were holding and that was still true.

## Decision

**None yet. This ADR exists to stop the corpus growing before these are settled.**

The three questions, and the options as they stand:

### 1. Where do reports live, and how does the ceiling announce itself?

One question, not two: the storage choice and the failure behaviour are the same
decision. Any answer that leaves the ceiling invisible is not an answer, because
a service that has quietly stopped caching is indistinguishable from one with a
poor hit rate — same latency, same bill, same green dashboard.

| option | cost shape | failure mode |
|---|---|---|
| **A budget with volatile eviction** (today, by default rather than by choice) | memory, capped at 1 GiB | entries silently evicted; the evicted customer sees an ordinary-looking miss and the evicting job succeeds |
| **A budget with `noeviction`** | memory, capped | writes refused at the ceiling — loud at the write site, but the service stops caching entirely until someone intervenes |
| **A larger budget** | memory, capped higher | moves the ceiling; changes nothing about which failure happens at it |

Moving reports to a durable store with Redis as an index was considered and
**dropped**. It is the option that stops the corpus being priced as memory, and
at some size it becomes the right one — but it buys a second read path and a
latency budget to defend against a sub-10ms hit, to solve a problem we do not yet
have at our actual corpus size. Listing it as a peer option would have implied
the choice is live. It is not; revisit it when memory, measured, says otherwise.

So the corpus stays priced as memory, deliberately. The binding requirement on
whichever option wins is that **the ceiling is visible before it is reached**.
The metric now exists (`lei_redis_memory_bytes`, `lei_redis_maxmemory_bytes`,
`lei_redis_maxmemory_policy`); an alarm with headroom does not, and its threshold
is a policy value rather than an engineering one.

Note that the eviction question is no longer hypothetical: whichever way it is
answered, it is a **change** from what production does today, including the
answer "leave it alone". That should be a decision rather than an inheritance.

### 2. What bounds a single job?

A hard cap on repositories per request, independent of quota, so capacity is not
controlled by billing. The number should come from what a machine can hold at the
configured concurrency, not from a round figure.

### 3. Does the TTL survive?

Proposed replacement: **lazy revalidation on read**. Serve from cache; when an
entry is older than some age, `ls-remote` its stored `data.git.hash` against
`data.git.default_branch` before serving. Unchanged, extend it; moved,
re-analyse. No background watcher, no preload, no scheduled sweep — cost strictly
proportional to what is actually asked for, and the corpus grows only where it is
used.

This makes (1) more pressing, not less: entries would stop expiring, so the
corpus would only ever grow — and with the durable-store option dropped, it grows
in memory.

**And it changes which failure happens at the ceiling.** A `volatile-*` policy
can only evict keys that carry a TTL. The 30-day `SETEX` is therefore the only
reason production's eviction policy has anything to act on. Store entries
without a TTL and eviction finds nothing to evict, so the ceiling arrives as
refused writes instead — the failure this ADR originally, wrongly, believed was
already in force. Revalidating on read while still writing with a TTL keeps them
evictable; persisting them does not. That is a choice inside question 3, not a
detail of it.

## Consequences

Until this is decided:

- corpus build-up stays paused, and nothing preloads;
- the existing TTL keeps deleting good work, which is wasteful but bounded, keeps
  memory flat, and — given a volatile eviction policy — is also the only thing
  making entries evictable rather than the cache filling until something breaks;
- a large job is bounded only by quota, which is acceptable only while beta's
  free-tier limit is the binding constraint;
- the corpus stays priced as memory, which is now an accepted consequence rather
  than an open option, and the reason Redis memory needs a metric whichever way
  (1) is answered.

## Not verified

- **How production's Redis came to be configured this way**, and whether the
  policy was chosen or inherited. The operations note documents something else
  entirely, so at least one of the two was never true.
- **Resident memory at corpus scale.** The provider does not report
  `used_memory_rss` or a fragmentation ratio, so the 10-14x fragmentation in the
  operations notes cannot be confirmed against production. Payload is still not
  resident memory, and the gap is now unmeasurable from here.
- **What concurrency the machine actually survives** with the long tail of clone
  sizes. #158 is the only evidence, and it concerned trending, not customer jobs.
