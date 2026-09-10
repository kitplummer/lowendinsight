# Production Readiness Plan

**Status:** Proposed
**Date:** 2026-09-08
**Production target:** Fly.io (`lowendinsight.dev`)
**Long-term target:** uds-core / uds-data (tracked separately in #19, #6)

## The governing rule

**Nothing is "done" until it answers correctly on `https://lowendinsight.dev`.**

Every stage below ends in a verification step against the live host, not a test
suite. This is the single change that matters most.

Three separate features were merged with passing tests and green CI, and none of
them have ever worked in production:

| Feature | Merged as | Live behaviour |
|---|---|---|
| ACP checkout | closed, PR #39 | 404 on every route |
| `/v1/health` | bead `lowendinsight-1mn`, closed | 401, not routed |
| `/healthz`, `/readyz`, `/metrics` | commit `93686bf` | 404, not routed |

In all three cases the code was correct. The definition of done was "tests green
and PR merged" rather than "responds correctly on the live host," and nothing in
the loop noticed the difference.

## Current state (verified 2026-09-08)

### Eight routes in `Lei.Web.Router` are unreachable in production

`LowendinsightGet.Endpoint` only forwards to `Lei.Web.Router` for paths matching
`@auth_paths` (`apps/lowendinsight_get/lib/lowendinsight_get/endpoint.ex:16`).
Everything else falls through to the endpoint's own catch-all 404.

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

`fly.toml` sets `http_checks = []` and relies solely on `tcp_checks`. Fly knows
only whether the port accepts TCP; a wedged application with an open socket looks
healthy. This is the likely cause of the recurring "lowendinsight unhealthy
(3 consecutive failures)" alerts.

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

`flyctl` was not available in the session that produced this document. The
following are unknown and are the first checks in Stage 3, not assumptions:

- region and instance count
- Fly Postgres backup schedule, and whether a restore has ever been tested
- whether Redis is durable or ephemeral

The last point matters: ADR-001 identifies the shared cache as the moat. If Redis
is ephemeral, the moat resets on restart.

---

## Stage 0 — Restore the signal

**Effort:** half a day to a day. **Blocks every later stage.**

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

## Stage 3 — Durability

**Effort:** 1-2 days. Starts by checking the unknowns listed above.

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

## Relationship to existing issues

- **#61** (GitHub Trending not running in production) is a symptom of the missing verification loop. Absorbed by Stage 0, not replaced.
- **#19** (Epic: UDS Integration) and **#6** (Helm chart) remain a separate long-term track. This plan does not replace them. Stages 0 and 1.2 advance both targets.
