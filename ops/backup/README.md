# The backup producer

A scheduled Fly Machine that dumps the production database, encrypts it, and
puts it in Tigris. `.github/workflows/backup.yml` verifies the result. ADR-006
has the reasoning.

There is deliberately no setup script. One existed; it failed three times, hung
on a prompt that needed `kill -9`, and asked for credentials that
`flyctl storage create` had already set. These are the commands it was wrapping,
which you can read before running.

## Facts you need

| | |
|---|---|
| app | `lowendinsight-backup` |
| database app | `lowendinsight-db` (postgres-flex: **HAProxy on 5432, Postgres on 5433**) |
| database name | `lowendinsight_get_prod` |
| dump role | `lei_backup`, read-only |
| bucket | `lei-pg-backups` (Tigris, via Fly) |

## 1. The bucket

```bash
flyctl storage create -n lei-pg-backups -o personal -a lowendinsight-backup
```

`-a` matters: it sets `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_ENDPOINT_URL_S3`, `AWS_REGION` and `BUCKET_NAME` as secrets on the app.
Without it the app has no credentials -- or keeps stale ones from a destroyed
bucket and uploads nowhere while reporting success.

It prints the keys once. They are already set on the app, so you do not need to
copy them anywhere, and should not paste them into a chat window or any terminal
that is being recorded.

Tigris holds a deleted bucket name for a while. If it refuses the name as
recently deleted, pick another and change it here, in
`.github/workflows/backup.yml` and in `scripts/backup-pull.sh`.

## 2. The dump role's password

Needed only because the existing one lives in a write-only CI secret and cannot
be read back.

```bash
flyctl ssh console -a lowendinsight-db
PGPASSWORD=$OPERATOR_PASSWORD psql -h 127.0.0.1 -p 5433 -U postgres -d lowendinsight_get_prod
```

```sql
ALTER USER lei_backup WITH PASSWORD 'something-without-at-slash-or-colon';
\q
```

`flyctl postgres connect` does **not** work on this cluster: there is no local
unix socket, and it fails with `server closed the connection unexpectedly`,
which reads like a database fault and is not one.

Avoid `@`, `/` and `:` in the password, or percent-encode it -- those characters
break the connection string below in ways that surface at 03:39 as something
unrelated.

## 3. The two secrets

```bash
flyctl secrets import -a lowendinsight-backup
```

It then waits on stdin with no prompt and no echo. That is flyctl's interface,
not a hang. Type or paste these two lines and press Ctrl-D:

```
PG_DUMP_URL=postgres://lei_backup:THEPASSWORD@lowendinsight-db.internal:5432/lowendinsight_get_prod
BACKUP_PASSPHRASE=THEPASSPHRASE
NTFY_TOKEN=tk_...
NTFY_TOPIC=...
```

The two ntfy values are the same ones in the repository's GitHub secrets. They
are what makes a failed attempt page; without them `backup.sh` checks for them,
finds nothing, and returns quietly, so a failed dump is silent and you find out
from the nightly verification a day later.

`BACKUP_PASSPHRASE` must match what the existing artifacts use, or old and new
backups need different keys. Use stdin rather than `flyctl secrets set`, which
would put both values in your shell history.

## 4. Build the image, create the schedule

```bash
cd ops/backup
flyctl deploy --build-only --push -a lowendinsight-backup
```

That prints an image reference. Then, once:

```bash
flyctl machine run <image-ref> \
  --schedule daily --restart on-failure \
  -a lowendinsight-backup --vm-memory 512 --region iad
```

**Fly's `--schedule daily` does not start this machine.** Across three
configurations over two days it never fired once; every start event reads
`SOURCE=user`. `backup-trigger.yml` starts it at 02:10 UTC instead, and waits for
a new exit event with code 0. The schedule stays on the machine in case Fly ever
begins honouring it -- two triggers would be a harmless no-op -- but it is not
what runs the backup. See the superseding section in ADR-006.

`--restart on-failure` is Fly's own default for a scheduled machine, and
overriding it with `--restart no` stopped the scheduler starting the machine at
all -- the backup neither retried nor ran, for 36 hours, while the config
cheerfully reported `schedule: "daily"`. See the superseded section in ADR-006.

A retry can still hide a systematic fault, so that is closed by paging instead:
`NTFY_TOKEN` and `NTFY_TOPIC` are set on this app and `backup.sh` pages on every
failed attempt, including ones a retry later recovers. Set them with the other
secrets in step 3 -- without them the paging path in `backup.sh` is dead code and
a failed dump is silent.

## 5. Prove it

```bash
flyctl machine list -a lowendinsight-backup
flyctl machine start <id> -a lowendinsight-backup
flyctl logs -a lowendinsight-backup
```

Expect a dump size, a table count, and `ok: dumps/YYYY/MM/DD/HHMMSSZ.dump.gpg`.
Then from the other side:

```bash
gh workflow run backup.yml && gh run watch
```

## Rebuilding after a change

Changing `backup.sh` or the Dockerfile needs a rebuild **and** a new machine: the
scheduled machine holds an image reference, not a tag.

```bash
cd ops/backup && flyctl deploy --build-only --push -a lowendinsight-backup
flyctl machine list -a lowendinsight-backup
flyctl machine destroy --force <old-id> -a lowendinsight-backup
flyctl machine run <new-image-ref> --schedule daily --restart on-failure \
  -a lowendinsight-backup --vm-memory 512 --region iad
```

`./refresh-digest.sh` prints the current digest of `postgres:17-bookworm` for the
`FROM` line. It is pinned so that what runs with these credentials changes only
when someone decides it should.

## Things that cost time, written down

**`flyctl storage create -a <app>` does not overwrite secrets that already
exist.** If the app already has `AWS_ACCESS_KEY_ID` or `BUCKET_NAME` from an
earlier bucket, a new bucket leaves them pointing at the old one, and the
producer fails with `AccessDenied` or `NoSuchBucket` naming a bucket you
destroyed. Verify what the machine actually receives rather than what you
believe you set:

```bash
flyctl machine run <image-ref> -a lowendinsight-backup --restart no --region iad \
  --vm-memory 256 --entrypoint /bin/sh -- \
  -c 'echo "BUCKET=[$BUCKET_NAME] KEY8=[$(printf %.8s "$AWS_ACCESS_KEY_ID")]"'
flyctl logs -a lowendinsight-backup   # then destroy the machine
```

**`flyctl secrets set` fails on this app** with `app has no current release`,
because the app is build-only and has never been deployed. Use
`flyctl secrets import --stage` (or `secrets set --stage`) instead.

**A machine takes its secrets when it is created.** Staging a secret does
nothing to a machine that already exists -- destroy it and run it again.

**Pass `flyctl machine run` a tag, not a digest.** Given
`repo@sha256:...` it appends the digest a second time and fails with
`invalid image identifier`.

## The keys, and which is which

Three, with distinct jobs. Tigris shows a secret key **once**, at creation, and
it is not recoverable afterwards -- the producer's was lost that way and had to
be replaced. Store both halves of any key you create.

| key | holder | permission | why |
|---|---|---|---|
| producer | the Fly machine's secrets | read-write | uploads the nightly dump and `meta/latest` |
| ci-verify | GitHub secrets | **read-only** | CI must not be able to overwrite or delete a backup |
| operator-backup-pull | a human, in a password manager | **read-only** | `scripts/backup-pull.sh` only reads |

The operator key is read-only on purpose. An earlier version of the pull script
wrote a `meta/last-local-pull` object to the bucket, which forced a human doing a
read-only job to hold a key that could delete every backup -- and meant a
read-only key could never clear the nightly staleness warning. The date is now
recorded as the `LEI_LAST_BACKUP_PULL` repository variable via `gh`, which CI
reads directly.

Delete keys scoped to a destroyed bucket. They still authenticate to the account
and do nothing else.
