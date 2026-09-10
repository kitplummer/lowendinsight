# Production Readiness Plan

**Status:** Accepted, in progress
**Date:** 2026-09-08
**Last updated:** 2026-09-10
**Production target:** Fly.io (`lowendinsight.dev`)
**Long-term target:** uds-core / uds-data (tracked separately in #19, #6)

| Stage | State |
|---|---|
| Stage 0 — Restore the signal | **Done**, deployed v120-v124 (#69) |
| Stage 1 — A deploy you can trust | Open (#65) |
| Stage 2 — Turn on the revenue path | Open (#66) |
| Stage 3 — Durability | Partly done (#67) |
| Stage 4 — Reassess automation | Not started |

> **Reading note.** The "Current state" findings below are a snapshot taken on
> 2026-09-08 and most have since been fixed. They are kept as the record of what
> was actually wrong, because the *pattern* they document is the point of this
> plan. Each is annotated with its resolution.

## The governing rule

**Nothing is "done" until it answers correctly on `https://lowendinsight.dev`.**

Every stage below ends in a verification step against the live host, not a test
suite. This is the single change that matters most.

Three separate features were merged with passing tests and green CI, and none of
them have ever worked in production:

| Feature | Merged as | Live behaviour (2026-09-08) | Resolved |
|---|---|---|---|
| ACP checkout | closed, PR #39 | 404 on every route | #62, deployed v120 |
| `/v1/health` | bead `lowendinsight-1mn`, closed | 401, not routed | #69, deployed v120 |
| `/healthz`, `/readyz`, `/metrics` | commit `93686bf` | 404, not routed | #69, deployed v120 |

Two more instances of the same pattern surfaced on 2026-09-09, after this plan
was written:

| Feature | Live behaviour | Resolved |
|---|---|---|
| GitHub trending | 200 with a plausible report ID and **zero repos** | #70, #72, closed #61 |
| `/readyz` | reported `ok` while Redis was entirely unreachable | #70, deployed v122 |

The second is the sharpest example, because the readiness probe added by this
very plan was blind to the service's most important dependency. A sixth
instance appeared in the test suite: a flaky test in #70 manufactured a green
merge signal (#71).

**Six instances, one shape: something reports success while broken.** That is
the whole argument for Stage 1's deploy gate (#65) and guard verification (#68).

In all three cases the code was correct. The definition of done was "tests green
and PR merged" rather than "responds correctly on the live host," and nothing in
the loop noticed the difference.

## Current state (verified 2026-09-08)

### Eight routes in `Lei.Web.Router` are unreachable in production

**Resolved in #69, deployed v120.** All eight routes now answer correctly in
production; `scripts/smoke-test.sh` asserts every one of them.

`LowendinsightGet.Endpoint` only forwarded to `Lei.Web.Router` for paths matching
`@auth_paths` (`apps/lowendinsight_get/lib/lowendinsight_get/endpoint.ex:16`).
Everything else fell through to the endpoint's own catch-all 404.

| Route | Live | Cause |
|---|---|---|
| `GET /healthz` | 404 | not in `@auth_paths` |
| `GET /readyz` | 404 | not in `@auth_paths` |
| `GET /metrics` | 404 | not in `@auth_paths` |
| `GET /v1/health` | 401 | auth plug gates any path containing `/v1`, then not forwarded |
| `POST /v1/orgs` | 401 | same |
| `POST /v1/orgs/:slug/keys` | 401 | same |
| `GET /v1/orgs/:slug/keys` | 401 | same |
| `DELETE /v1/orgs/:slug/keys/:key_id` | 401 | same |

The `/v1/orgs` family being dead means programmatic org and API-key provisioning
does not exist in production. The HTML dashboard is the only way to obtain a key,
which is a direct constraint on the business-to-agent story in ADR-001.

### No HTTP health checking

**Resolved in #69.** `fly.toml` now runs HTTP checks against `/healthz`
(`restart_limit = 3`) and `/readyz` (`restart_limit = 0`). Both have reported
passing continuously since v120, and the 10s `/healthz` grace period -- flagged
at the time as an estimate rather than a measurement -- held across four deploys
with no restart loop.

Previously `fly.toml` set `http_checks = []` and relied solely on `tcp_checks`.
Fly knew only whether the port accepted TCP; a wedged application with an open
socket looked healthy.

Neither `apps/lowendinsight_get/k8s/deployment.yaml` nor
`apps/lowendinsight/manifests/deployment.yaml` defines a `livenessProbe` or
`readinessProbe`, so the UDS path would be equally blind for the same reason.

### No migrations in the deploy path

There is no `release_command` in `fly.toml`, no migrate step in the Dockerfile
`CMD`, and no `Release` module. Migrations have only ever been run by hand.

`LowendinsightGet.Repo` and `Lei.Repo` are both configured from the same
`DATABASE_URL` (`config/runtime.exs`), so two migration directories share a
single `schema_migrations` table.

### No deploy automation

`.github/workflows/release.yml` builds and pushes a GHCR image on `v*` tags.
Nothing deploys to Fly. Deploys have been manual or agent-driven, which matches
the stalled deploy beads (`lowendinsight-c1n`, `lowendinsight-av8`).

### Config drift

- `lei_base_url` defaults to `https://lowendinsight.fly.dev` (`config/runtime.exs`); the live host is `lowendinsight.dev`.
- `scripts/smoke-test.sh` and `scripts/billing-smoke-test.sh` default to the same stale host.
- `DATABASE_URL` falls back silently to `localhost` in production. Only `LEI_JWT_SECRET` raises when unset.

### Not verified

`flyctl` was not available in the session that produced this document. Answered
since:

| Question | Answer |
|---|---|
| Region and instance count | **Single machine in `iad`.** No redundancy; every deploy is downtime, not a rolling update. |
| Redis durable or ephemeral | **Wrong question.** Redis was not a persistence problem -- the app could not reach it at all. See below. |
| Postgres backup schedule | **Still unknown.** No restore has been tested. Remains the first task in Stage 3 (#67). |

### The Redis outage (2026-09-09)

Redis was unreachable for the entire period this plan was being executed, and
nothing surfaced it. The cause was not configuration drift or credentials:

> Redix defaults to `socket_opts: [:inet]` (IPv4). Fly's private network is
> IPv6-only. The Postgres config alongside it had always set
> `socket_options: [:inet6]`; Redis was simply missing the equivalent.

Fixed in #72, deployed v124, confirmed by `/readyz` reporting
`{"redis":"ok","database":"ok"}`.

Two lessons worth keeping:

- `%Redix.ConnectionError{reason: :closed}` does **not** mean the server closed
  the connection. With `sync_connect: false` it is what Redix returns whenever
  the background connect never succeeded. It means "not connected" and says
  nothing about why. Two wrong diagnoses (`LEI_GH_TOKEN`, then TLS) followed
  from reading it as a server-side close.
- The answer was visible in a config asymmetry between two adjacent
  dependencies. Reading production logs before reasoning from source would have
  found it faster.

**Consequence while it was down:** every analysis billed as a cache miss --
`$0.05` instead of `$0.005` under ADR-001, a 10x overcharge -- and the "moat"
the pricing model rests on was not operating at all.

---

## Stage 0 — Restore the signal — **DONE**

Delivered in #69, deployed v120 on 2026-09-08. Verified by
`./scripts/smoke-test.sh https://lowendinsight.dev` passing 26/26 against the
live host.

| # | Task | Location |
|---|---|---|
| 0.1 | Add `/healthz`, `/readyz`, `/metrics`, `/v1/health`, `/v1/orgs` to `@auth_paths` | `endpoint.ex:16` |
| 0.2 | Allow `/v1/health` past the auth plug | `auth.ex:70` |
| 0.3 | Replace `tcp_checks` with an HTTP check against `/healthz` | `fly.toml` |
| 0.4 | Fix stale default host in both smoke scripts | `scripts/` |
| 0.5 | Add smoke assertions covering all eight previously dark routes | `scripts/smoke-test.sh` |

**Verify:** `./scripts/smoke-test.sh https://lowendinsight.dev` exits 0, and
`/metrics` returns Prometheus text.

**Not Fly-specific.** Kubernetes probes and uds-core monitoring need exactly
these endpoints. Stage 0 is a shared prerequisite for both deployment targets.

## Stage 1 — A deploy you can trust

**Effort:** 2-3 days.

| # | Task | Notes |
|---|---|---|
| 1.1 | Decide the migration story | Separate databases, or consolidate to one repo. A design decision, and harder to reverse under UDS where the repos may be backed by different operator-managed databases. Resolve while Fly is the only consumer. |
| 1.2 | Add `LowendinsightGet.Release.migrate/0` | Put the logic in a module, not inline in `fly.toml`. Fly calls it via `release_command`; a Helm `pre-upgrade` hook or Zarf action calls the same function later. Portable by construction. |
| 1.3 | Add `release_command` to `fly.toml` | Migrations run before the new version takes traffic. |
| 1.4 | GH Actions deploy on `main` | build -> deploy -> smoke gate -> auto-rollback on non-zero exit. |
| 1.5 | Prove the rollback | Deploy something deliberately broken and confirm it rolls back. An untested rollback is not a rollback. |

## Stage 2 — Turn on the revenue path

**Effort:** 2-3 days.

| # | Task |
|---|---|
| 2.1 | Merge PR #62 (ACP mount + raw-body fix) |
| 2.2 | Fix `lei_base_url` default in `config/runtime.exs` |
| 2.3 | Set `STRIPE_*`, `LEI_ACP_BEARER_TOKEN`, `LEI_ACP_SIGNING_SECRET` |
| 2.4 | Register the Stripe webhook endpoint; confirm a real signed event verifies |
| 2.5 | End-to-end: ACP checkout -> key issued -> analyze -> usage recorded -> `cost_cents` returned -> Stripe usage record |

**Order matters at 2.3.** Setting these secrets before #62 merges would break both
ACP and Stripe webhook verification. `conn.private[:raw_body]` is nil in
production today, because the endpoint's `Plug.Parsers` consumes the body before
the sub-routers' `RawBodyReader` can capture it. Both signature checks pass
currently only because the secrets are unset and verification is skipped.

## Stage 3 — Durability — **PARTLY DONE** (#67)

Redis availability resolved (#72). Remaining: Postgres backup verification,
Redis persistence config, `DATABASE_URL` fail-fast, listener documentation, and
one new item -- **rotate the Redis credential**, which was written to Fly's log
stream on every boot until #72 removed the line.

| # | Task |
|---|---|
| 3.1 | Confirm Fly Postgres backups exist, and restore one into a scratch database |
| 3.2 | Determine whether Redis is durable; if not, decide whether that is acceptable given ADR-001 |
| 3.3 | Make `DATABASE_URL` fail fast instead of falling back to `localhost` |
| 3.4 | Document why two HTTP listeners exist (see below) |

### Do not remove the second listener

`config/runtime.exs` sets `start_http: true` with `http_port: 4000`, starting a
second Cowboy listener for `Lei.Web.Router` alongside the endpoint on 8080.

On Fly this listener is unused, since only 8080 is routed. It is **not** dead
code: `apps/lowendinsight/manifests/service.yaml:12` targets port 4000, making it
the Kubernetes and Zarf entry point. Removing it would break the UDS path.

Separately, `k8s/deployment.yaml:35` exposes `containerPort: 4444` while
`k8s/service.yaml:14` targets 4000. This mismatch is pre-existing and harmless on
Fly, but should be resolved before UDS work resumes.

## Stage 4 — Reassess automation

Keiro is not running as of 2026-09-08. Of 158 beads, 18 were product work and 112
(71%) were the orchestration system managing itself: 57 TQM alerts, 33 UplinkAgent
failures, 16 orchestrator stalls, 4 architect scans, 2 health alerts.

Every failure category was in the orchestration layer, not in code generation.
The gap was verification, not authoring, which is why Stage 0 comes first: more
autonomy does not fix a definition of done that cannot distinguish a working
deploy from a broken one.

**Gate for reconsidering automation:** a bead may only close when the smoke gate
passes against production.

### What execution actually demonstrated (2026-09-08 to 09-10)

Six PRs merged. Two of them fixed defects introduced by earlier PRs in the same
sequence -- the `/readyz` blind spot came from Stage 0 itself (#70), and a flaky
test from #70 turned `main` red after merging on a green that was luck rather
than evidence (#71).

Both were caught by CI or by the operator, not by the author. That is an
argument for **#65** and **#68** ahead of the rest of this plan, including ahead
of the revenue work in #66:

- A fix sat merged and green for a day while production stayed broken, purely
  because deploying is a separate step a human has to remember. A rebuild was
  also indistinguishable from a fresh deploy without inspecting release history
  and boot logs. Stage 1 removes both.
- Running a test once and seeing green does not establish that the test means
  anything. #68 makes that mechanical.

## Relationship to existing issues

- **#61** (GitHub Trending not running in production) — **closed 2026-09-10.** It was a symptom, though not of the routing gap as predicted here: the trending job was a victim of the Redis outage, crashing on `CaseClauseError` in `Datastore` and having nowhere to persist results.
- **#19** (Epic: UDS Integration) and **#6** (Helm chart) remain a separate long-term track. This plan does not replace them. Stages 0 and 1.2 advance both targets.
