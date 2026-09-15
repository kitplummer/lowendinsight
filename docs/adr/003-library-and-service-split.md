# ADR-003: The library is an analyzer; the service is a separate app

**Status:** Accepted (2026-09-15)

## Context

`lowendinsight` is published to Hex as a library. Over time the hosted
service's business layer was built inside it: `Lei.Repo` (Postgres), orgs and
API keys, authentication, credits and payments (MPP, Tempo, Stripe), webhooks,
usage and reconciliation, agent checkout, wallets, health and metrics, rate
limiting, and the dashboard router and sessions.

As a result the library app declared `ecto_sql`, `postgrex`, `joken`, `plug`
and `plug_cowboy` as runtime dependencies, and its OTP application started a
database repo, payment and Stripe processes, and optionally an HTTP server. An
application adding `{:lowendinsight, ...}` would get all of that, and would
fail to boot without the service's database configuration.

## Decision

- **`apps/lowendinsight` is the analyzer only**: git analysis, risk scoring,
  SBOM parsing, scanners, and the `Lei.*` modules that are analyzer tooling
  (`AgenticDetector`, `Cache.*`, `BatchCache`, `BatchAnalyzer`, `Rules`,
  `Sarif`, `Sbom`, `ZarfGate`, `OCI.Annotations`), plus the command-line mix
  tasks. No database, web server or JWT dependency. Its application starts
  only `Lei.BatchCache`.
- **`apps/lei_service` is the service.** Every other `Lei.*` module lives
  there, with its tests, templates and static assets (`priv/lei/`), and
  `Lei.Repo`, whose migrations are in `priv/lei_repo/migrations` with their
  original versions. `Lei.Boot` holds the boot checks and the service processes
  `LeiService.Application` starts.
- Module names are unchanged (`Lei.*`), so the move is reviewable as moves.

## Consequences

- The production database needs no migration: `schema_migrations` is shared,
  and the migrations keep their versions. Verified by running the release's
  `LeiService.Release.migrate()` against a migrated database (nothing
  run) and an empty one (all created).
- `Lei.Repo`'s `priv:` must be set in config, not on `use Ecto.Repo`, where it
  is ignored (`Lei.RepoMigrationsPathTest`).
- Follow-ups, in order:
  1. Move the service's settings from the `:lowendinsight` application env to
     `:lei_service`, so the library's env holds only analyzer settings.
  2. Prove the library stands alone: a CI job that builds a fresh project
     depending only on `lowendinsight`, boots it with no configuration, and
     analyzes a local repository; `mix hex.build` shows only analyzer
     dependencies.
  3. Rename the service app from `lowendinsight_get` to `lei_service` (done:
     modules `LeiService.*`, OTP app `:lei_service`, release `lei_service`).
     `LowendinsightGet.AnalysisWorker` remains as a delegating module so Oban
     jobs stored under the old worker name still run; remove it once no
     `oban_jobs` row names it.
  4. Release 0.10.0 of the library.
