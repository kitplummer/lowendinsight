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

### Reports live in Redis, and Redis is unbounded with no eviction

From `apps/lei_service/docs/OPERATIONS.md`:

```
maxmemory:        unlimited (default)
maxmemory_policy: noeviction
```

Two consequences, and the second is the one that matters.

**No eviction is right.** A large job cannot push another customer's entries out.
The shared corpus is not a noisy-neighbour lottery, and it should stay that way.

**Unbounded with `noeviction` fails invisibly.** At the memory ceiling Redis
begins refusing *writes* while continuing to serve *reads*. Analyses keep
succeeding. Nothing caches. Every subsequent request is a miss — full clone, full
price, full latency — and the service reports itself healthy throughout, because
every individual request works. It is the failure shape this codebase has shipped
nine times: something reporting success while broken. Today nothing measures
Redis memory, nothing alarms on it, and `/readyz` checks only that Redis answers.

The corpus is therefore priced as **memory**, roughly an order of magnitude above
disk, and it does not degrade gracefully — it works, then it silently stops
caching.

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
| **Redis only** (today) | memory, growing with the corpus | silent write failure at the ceiling |
| **Redis with a memory budget** | memory, capped | needs an eviction policy, which reintroduces the noisy-neighbour problem the current config avoids |

Moving reports to a durable store with Redis as an index was considered and
**dropped**. It is the option that stops the corpus being priced as memory, and
at some size it becomes the right one — but it buys a second read path and a
latency budget to defend against a sub-10ms hit, to solve a problem we do not yet
have at our actual corpus size. Listing it as a peer option would have implied
the choice is live. It is not; revisit it when memory, measured, says otherwise.

So the corpus stays priced as memory, deliberately, and the binding requirement
on whichever option wins is that **the ceiling is visible before it is reached**:
Redis memory as a metric, an alarm with headroom, and a cache write failure that
is loud rather than absorbed.

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

## Consequences

Until this is decided:

- corpus build-up stays paused, and nothing preloads;
- the existing TTL keeps deleting good work, which is wasteful but bounded and
  keeps memory flat;
- a large job is bounded only by quota, which is acceptable only while beta's
  free-tier limit is the binding constraint;
- the corpus stays priced as memory, which is now an accepted consequence rather
  than an open option, and the reason Redis memory needs a metric whichever way
  (1) is answered.

## Not verified

- **Actual Redis memory in production.** Not exposed in `/metrics`. Payload size
  is not resident memory: the operations notes record 10-14x fragmentation at
  small dataset sizes, and nobody has measured it at corpus scale.
- **What concurrency the machine actually survives** with the long tail of clone
  sizes. #158 is the only evidence, and it concerned trending, not customer jobs.
