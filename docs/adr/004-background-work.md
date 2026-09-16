# ADR-004: Background work runs as Oban jobs

**Status:** Accepted (2026-09-15)

## Context

The service does work outside the request that asked for it in four ways, and
only one of them survives a restart.

| mechanism | used for | on crash or deploy |
|---|---|---|
| Oban (`analysis` queue, concurrency 5) | uncached analyses for `/v1/analyze` | job row persists; nothing rescued it until Lifeline (#194) |
| Quantum cron, in the web node | trending refresh (hourly, synchronous, in the scheduler process); cache cleaner (every 5 min) | the run is lost; the next tick starts over |
| `Task.start` fire-and-forget | usage recording (`Lei.UsageTracker.record_usage_async/4`), API key `last_used_at`, background refresh of cached reports (`LeiService.Analysis`), the operator trending trigger | lost, silently |
| batch "pending" markers (`Lei.BatchAnalyzer.schedule_analysis/2`) | uncached batch dependencies | nothing ever runs them: a marker is written, no work is queued |

What that has cost, all found in the last week:

- **79 analyses never finished.** Production ran Oban with no plugins. Jobs
  executing when the node stopped stayed `executing` forever: 60 midnight
  trending batches (2026-09-10..14) and 19 single-repository requests. Fly
  gives the node 5 seconds to stop (`kill_timeout = 5`), so every deploy kills
  whatever is running.
- **Trending exhausted the node's memory** (#158). Fourteen languages of large
  clones ran at once in the process serving requests. The fix made trending
  synchronous and one language at a time, but it still runs inside the web
  node, in the scheduler process.
- **The Oban schema was a version behind** the installed Oban, unnoticed (#194).
- **Uncached batch dependencies are marked pending and never queued**, so
  the analysis a batch response promises does not happen.
- **Usage recorded with `Task.start` is lost** if the node stops before the
  task runs, which is revenue the ledger never sees.

The common shape is the one CLAUDE.md warns about: the request returns
success, and the work it promised is not durable, not bounded, and not
observable.

## Decision

**Work that must happen is an Oban job.** Oban is already a durable,
Postgres-backed queue in production; the problem was running it bare, and
beside three other mechanisms. No new infrastructure.

1. **One mechanism.** Every piece of deferred work that a customer, the ledger
   or a published report depends on is enqueued with `Oban.insert` in the same
   transaction as the state that promises it, or is done synchronously. No
   `Task.start` for anything whose loss matters.
   - Uncached batch dependencies enqueue analysis jobs; the batch response
     returns job ids.
   - Usage recording is written in the request's transaction, not
     fire-and-forget. It is a ledger fact (ADR-002).
   - Trending becomes one job per language on its own queue, scheduled by
     `Oban.Cron`; the operator trigger enqueues instead of spawning.
   - The cache cleaner moves to `Oban.Cron`, retiring Quantum.
   - `last_used_at` may stay fire-and-forget: losing one is harmless.

2. **Queues sized by what they cost.**
   - `analysis` for customer requests.
   - `trending` at concurrency 1, lower priority, so a large clone never
     starves a paying request.
   - `maintenance` at concurrency 1.

3. **Every worker is bounded.** Each worker defines `timeout/1` and
   `max_attempts`. Lifeline's `rescue_after` exceeds the longest timeout, so
   it never re-runs work that is still running. Jobs are idempotent: an
   analysis writes its result under its uuid, so running one twice is safe.

4. **Deploys drain rather than kill.** `kill_timeout` and Oban's
   `shutdown_grace_period` are set together, long enough for a typical
   analysis to finish. A longer job is rescued by Lifeline and re-run.

5. **Stuck work is visible.** The service exposes queue depth, the age of the
   oldest available job, and the count of jobs executing longer than their
   timeout. The monitor fails when any job has been executing past its
   timeout, or available for longer than a threshold. "The queue is healthy"
   must be checked, not assumed.

## Consequences

- One place to look for "did the work happen": the `oban_jobs` table, with
  Pruner keeping it bounded.
- Enqueue-in-transaction means a request that promises work and a job that
  does it cannot disagree.
- Postgres carries the queue. At current volume this is far below what Oban
  handles; if trending's memory use still competes with requests, the
  `trending` queue can run on a separate Fly process group reading the same
  table, without code changes.
- Quantum is removed once its two jobs move.
- Lifeline in open-source Oban rescues by time alone, so a job that
  legitimately exceeds `rescue_after` would run twice. Bounded timeouts (3)
  make that a configuration error, which a test can check.

## Rollout

Each step is its own PR with a failing test first:

1. **Oban 2.24, schema v14, Lifeline and Pruner** (#194); the 79 orphaned
   jobs handled by `scripts/ops/orphaned-jobs.sh`.
2. **Queue health on `/readyz` and in the monitor**, so the next steps are
   observed as they land.
3. **Worker timeouts, and `kill_timeout` / `shutdown_grace_period`.**
4. **Batch misses enqueue jobs.**
5. **Usage recording in the request transaction.**
6. **Trending and the cache cleaner as Oban jobs and cron**; remove Quantum.

## Not decided here

- Whether trending runs on a separate machine. Revisit with memory metrics
  after step 6.
- Oban Pro (smarter Lifeline, workflows). Not needed for the above.
