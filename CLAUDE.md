# Working in this repository

## Toolchain

Elixir 1.16.3 / OTP 26.2, pinned in `.tool-versions` and matched exactly by CI.

```bash
mise install          # precompiled OTP, ~40s. asdf builds from source; mise does not
```

Postgres and Redis must be running locally. `config/test.exs` expects
`postgres:postgres@localhost` and `redis://localhost:6379/2`.

## Before opening or updating a PR

```bash
scripts/preflight.sh
```

Seven stages: format, compile (warnings are errors), databases, suite, guards,
seed sweep, backup grants. CI runs the same script. When local and CI disagree
about what "passing" means, the weaker one wins by default and nobody notices.

`--quick` skips the seed sweep and grant check for iteration. Do not open a PR
on a `--quick` run: those two stages cover the ordering and migration-drift
bugs that have actually reached production here.

## The rules that cannot be mechanised

These are the ones no script enforces, which is why they are written down.

**Reproduce before fixing.** Reasoning from source has been wrong here
repeatedly. `LEI_GH_TOKEN` was named as a root cause twice before production
logs showed the real fault was Redix defaulting to IPv4 on an IPv6-only
network. Read the logs, run the failing case, or say plainly in the PR that you
could not and what you did instead.

**Identify the mechanism, not a mechanism.** A `try/after` was shipped for a
working-directory bug on the theory that a raise skipped the restore. The real
mechanism was concurrency -- the value being restored was already another
task's directory. The fix moved CI from 3/5 seeds passing to 4/5 and looked
like progress. If a fix only partly works, the theory is probably wrong; do not
patch further until you can explain the remainder.

**Write the failing test first, and prove it fails.** A test written after the
fix tends to assert what the code now does. Add a mutation to
`scripts/mutations.json` so the proof is permanent and runs on every PR.

**Never claim green without naming what ran.** "Tests pass" has been true while
production was broken. Say which suites, how many seeds, and against what.

**Say what you did not verify.** The `Not verified` section of the PR template
is required. Gaps that read as completeness are how most defects here reached
production.

## Before pushing anything non-trivial, re-read the diff for

- **Concurrency** -- is this state global to the node? `File.cd`, application
  env, ETS and the working directory all are. Analyses run under
  `Task.async_stream`, so save-and-restore of global state is racy by
  construction.
- **Partial failure** -- if this fails halfway, what is left behind? Two writes
  describing one event belong in one transaction. External calls do not belong
  inside one.
- **Empty and zero** -- does the check still mean anything when the input is
  empty? A scan matching no files, a manifest with no entries, a `sum` over no
  rows. Several checks here have passed by examining nothing.

## The failure mode this codebase has

Nine-plus defects have shipped under green CI. The shape is always the same:
**something reports success while broken.** ACP routes 404ing, `/readyz` green
with Redis dead, trending returning empty reports with a fabricated UUID,
metered billing broken three ways, a test retry loop converting ordering bugs
into passes, a backup verifier checking a hardcoded table list, a mutation
manifest that reported "all guards verified" having verified nothing.

When adding a check, ask what it does when it cannot do its job. If the answer
is "passes", it is not a check.

## Verification layers

| | |
|---|---|
| `umbrella_ci` | does the code work |
| `guard-verification` | would the tests catch the bug coming back |
| `backup-grants` | can the backup role dump what migrations create |
| `deploy` | does it work in production |
| `monitor` | is it still working, every 15 minutes |

Each exists because the one above it was green while something was broken.

## Conventions

- Migrations run as the `lowendinsight` role in production; the backup role's
  grants depend on that. See `apps/lowendinsight_get/docs/OPERATIONS.md`.
- Money is integer credits, never floats or `Decimal`, in the ledger.
  One credit is $0.001, matching the Stripe meter unit.
- The ledger is append-only. Balance is a sum, never a column.
- Secrets go in over stdin (`flyctl secrets import`, `gh secret set`), never as
  a command argument.

## Architecture decisions

`docs/adr/` -- ADR-001 pricing, ADR-002 the credit ledger and payment rails.
Read ADR-002 before touching anything under `Lei.Credits`.
