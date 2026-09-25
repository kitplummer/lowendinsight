# ADR-006: The Backup Is Taken Near the Data, and Verified Away From It

**Status:** Proposed
**Date:** 2026-09-25
**Authors:** Kit Plummer, Claude (AI pair)
**Amends:** the backup topology described in `apps/lei_service/docs/OPERATIONS.md`

## Context

The off-platform backup ran on a GitHub runner. To reach a database that has no
public address, each nightly run had to:

1. install a third-party action, resolved from `@master`
2. download a flyctl binary, resolved as `latest`
3. authenticate to Fly with a database-scoped token
4. add the pgdg apt repository and install `postgresql-client-17`
5. open `flyctl proxy` over WireGuard, backgrounded in one step and used in the
   next
6. run `pg_dump` through that proxy
7. encrypt, and upload the artifact to GitHub

Seven external dependencies, each somebody else's uptime, every night,
unattended.

### What actually happened

Measured from the run history rather than argued:

| date | failed at | cause |
|---|---|---|
| 2026-09-12 | `Dump` | `permission denied for table credit_entries` -- a missing grant |
| 2026-09-23 | `setup-flyctl` | the action failed with **no output at all**; every later step skipped |
| 2026-09-24 | `Dump` | `server closed the connection unexpectedly`, 81 seconds in |

Three scheduled failures in roughly fourteen nights, from three unrelated
causes. The grant failure produced the `backup-grants` verification stage, which
now guards that class. The other two remain.

And on both 09-23 and 09-24 the page that should have said so was **rejected by
ntfy with an HTTP 401**. The backup did not happen, twice, and nobody was told
either night. The credential had been proved once by hand on 2026-09-17 and
assumed to hold; the monitor now probes it every 15 minutes.

### Why the 09-24 cause is still unknown

It is not diagnosable from what we keep. `flyctl proxy` is backgrounded in one
step and used in the next, so anything it says after its own step closes goes
nowhere, and nothing checks the process is still alive when the dump fails.
`flyctl logs` retains about forty minutes, so the server side is gone too.

That is the strongest argument in this document. Not that the proxy is
unreliable -- it worked on most nights -- but that when it failed we could not
find out why, and a backup path whose failures are unexplainable is one that
cannot be improved.

## Decision

**Production takes its own backup. CI verifies it.**

A scheduled Fly Machine in the same organisation and private network as the
database dumps `lowendinsight-db.internal:5432` directly, encrypts, and writes
to a Tigris bucket. No proxy, no tunnel, no flyctl, no apt repository, no
runner.

CI's nightly job fetches the newest object and proves it is a backup: it is
recent, it decrypts, and **it restores into a real PostgreSQL 17 and answers
queries**. Two external dependencies where there were seven.

This follows the pattern the repository already trusts. `backup-grants` does not
grant; it checks that grants are right. `monitor.yml` does not serve traffic; it
checks that serving works. A check that also performs the work it checks fails
in both roles at once, which is what happened on 09-23: the action that would
have taken the backup failed, and because taking and verifying were the same
job, there was nothing left to report a verdict.

### The new failure mode, and the check that exists for it

Moving production out of CI introduces one failure that is worse than any it
removes: **a scheduled machine that stops running produces no failure
anywhere.** Not a red run, not a log line, not a page. Fly's scheduler skipping
it, an image that will not boot, a machine someone destroyed -- all silent.

So the freshness check is not a nicety, it is the load-bearing part of this
decision. An object older than 26 hours fails the build. Twenty-six rather than
twenty-four because Fly picks the minute within the day, so consecutive runs can
be slightly more than a day apart with nothing wrong.

Under the old design "the backup did not happen" and "the job failed" were the
same event. They are not any more, and the freshness limit is what keeps them
connected.

### Ordering, so a reader never sees a half-written backup

The producer writes `meta/latest` **after** confirming with `head-object` that
the dump it names is in the bucket. Readers follow that pointer instead of
sorting a listing, because sorting a listing finds an upload in progress and
calls it the newest backup.

### Blast radius, stated plainly

Tigris is provisioned through Fly (`flyctl storage create`) and lives in the
same organisation as the database. **The nightly copy therefore shares a fate
with the volume snapshots it exists to cover for.** That is a real reduction in
what this job insures against, and pretending otherwise would be worse than the
reduction.

Two things carry a copy off Fly:

- **CI uploads the artifact it verified**, on every green run, 90-day retention.
  Automatic, and it is the same thing this job did before the producer moved.
- **`scripts/backup-pull.sh`** puts a copy on a machine a human controls, and
  decrypts it with the passphrase from a password manager.

The second is not about durability -- the first covers that. It is the only
thing that can prove the passphrase **you** hold still opens these files. CI
decrypts with the CI secret, so it can only ever establish that CI agrees with
itself. A password-manager copy that drifted during a rotation is invisible from
CI and fatal in a recovery.

Because it is manual, it is the part that quietly becomes never. The script
records the date of each pull in the bucket, and CI reads it and warns past 30
days. Deliberately a warning: durability does not depend on it, and failing the
nightly backup over a human's calendar would make this job red for a reason that
is not about the backup -- and `monitor.yml` already documents what a
permanently red check does to the people meant to read it.

### No retries

The machine runs with `--restart no`, and the producer has no retry loop. A
failed backup must stay failed and be noticed. A retry that succeeds converts a
diagnosable fault into a green run, and this repository has shipped that mistake
already: a test retry loop that turned ordering bugs into passes.

## Consequences

### Positive

- **Five dependencies leave the nightly path**: the action, the flyctl binary,
  the Fly API, the WireGuard tunnel and the pgdg apt repository. Two of the
  three observed failures were in that set.
- **The dump is proved by restoring it.** The old job read the archive's table
  of contents; a table of contents parses for a dump that restores to nothing.
- **A dead producer is detected**, which the old design structurally could not
  distinguish from a failed job.
- **CI can no longer reach the database.** It holds a read-only bucket key and
  the passphrase, not `PG_DUMP_URL` and not a Fly token. The credential that
  could dump production is on the machine that needs it.
- **Failures become diagnosable.** The producer's output is a machine log that
  Fly retains, rather than a backgrounded process whose stderr went nowhere.

### Negative

- **The nightly copy is inside the Fly organisation**, as above. Mitigated by
  the CI artifact and the local pull, not eliminated.
- **A new Fly app to operate**, with its own image to rebuild when the postgres
  base image is bumped. `ops/backup/refresh-digest.sh` exists so that bump is a
  deliberate act rather than a moving tag.
- **The passphrase now lives in two places** -- the producer's Fly secrets and
  the CI secret -- and they must agree. A rotation that updates one and not the
  other is caught the next night by the decrypt step, which is a day's latency
  rather than immediate.
- **Verification is only as good as its restore target.** A `postgres:17`
  container is not production: extensions, roles and settings differ, and a dump
  that restores there could still need work against the real thing.
- **Fly chooses the minute.** There is no guarantee about *when* the backup is
  taken, only that one arrives within 26 hours.

### Neutral

- Volume snapshots are unchanged and remain the primary recovery mechanism.
- The artifact format is unchanged: `pg_dump --format=custom`, AES256 via gpg.
  Every existing artifact and every documented restore command still works.

## Open Questions

1. **Should the local pull be a warning forever?** It is a warning because
   durability does not rest on it. If the passphrase is rotated more than once
   without a pull, the argument changes -- but CI cannot see a rotation date, so
   there is nothing to check against yet.
2. **Should Tigris write through to a bucket outside Fly?**
   `flyctl storage create` supports `--shadow-write-through` to an external S3
   endpoint, which would make the off-Fly copy continuous and automatic instead
   of a 90-day CI artifact. It needs an account at a second provider and a
   second set of keys to hold.
3. **Does the restore target need to resemble production?** Loading the
   extensions and roles the real database has would turn this from "the dump
   restores" into "the dump restores into something like production". It is more
   moving parts in the one job whose job is being simple.

## References

- ADR-004 -- background work; the producer is deliberately *not* an Oban job,
  because a backup should not stop when the application cannot boot
- #19 -- the uds-core restore target the portable dump exists for
- `apps/lei_service/docs/OPERATIONS.md` -- "Backup & Recovery", the procedure
- `ops/backup/` -- the producer; `scripts/backup-pull.sh` -- the off-Fly copy
- Runs 35815183754 (09-23) and 35952344992 (09-24) -- the two failures, and the
  401s that meant nobody heard about either
