# LowEndInsight Operations Guide

This guide covers deployment, configuration, and operations for LowEndInsight (LEI) in production environments.

## Architecture Overview

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Clients   │────▶│  LEI-GET    │────▶│    Redis    │
│  (API/SBOM) │     │  (Elixir)   │     │   (Cache)   │
└─────────────┘     └──────┬──────┘     └─────────────┘
                          │
                          ▼
                   ┌─────────────┐
                   │  PostgreSQL │
                   │   (Oban)    │
                   └─────────────┘
```

**Components:**
- **LEI-GET**: Elixir/OTP application serving the REST API
- **Redis**: Cache storage for analysis reports
- **PostgreSQL**: Job queue persistence (Oban)

## Deployment Options

### Docker Compose (Development/Testing)

```yaml
version: '3.8'
services:
  lei-get:
    build: .
    ports:
      - "4000:4000"
    environment:
      - REDIS_URL=redis://redis:6379/0
      - DATABASE_URL=ecto://postgres:postgres@postgres/lei_service
      - SECRET_KEY_BASE=your-secret-key-base-here
    depends_on:
      - redis
      - postgres

  redis:
    image: redis:7-alpine
    volumes:
      - redis_data:/data

  postgres:
    image: postgres:16-alpine
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_DB=lei_service
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  redis_data:
  postgres_data:
```

### Kubernetes

See `k8s/` directory for Kubernetes manifests:
- `deployment.yaml` - LEI-GET deployment
- `service.yaml` - LoadBalancer service
- `redis-master-deployment.yaml` - Redis deployment
- `redis-master-service.yaml` - Redis service

### UDS (Unicorn Delivery Service)

LEI-GET is designed for UDS integration:

```yaml
# zarf.yaml example
components:
  - name: lei-get
    charts:
      - name: lei-get
        valuesFiles:
          - values.yaml
    images:
      - ghcr.io/kitplummer/lowendinsight-get:latest
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP server port |
| `LEI_ADMIN_TOKEN` | (unset) | Token for `/admin`. **Unset means /admin denies everyone** -- it fails closed by design, so the dashboard is unreachable until this is set. |
| `LEI_START_HTTP` | `true` | Start the standalone `Lei.Web.Router` listener (see [Two HTTP listeners](#two-http-listeners)) |
| `LEI_HTTP_PORT` | `4000` | Port for that standalone listener |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis connection URL |
| `DATABASE_URL` | - | PostgreSQL connection URL |
| `SECRET_KEY_BASE` | - | Secret for signing/encryption |
| `LEI_CACHE_TTL` | `30` | Cache TTL in days |
| `LEI_CACHE_TTL_SECONDS` | - | Cache TTL in seconds (overrides days) |
| `LEI_CACHE_CLEAN_ENABLE` | `true` | Enable cache cleanup job |
| `LEI_CHECK_REPO_SIZE` | `true` | Check repo size before cloning |
| `LEI_GH_TOKEN` | - | GitHub token for API calls |
| `LEI_BASE_TEMP_DIR` | `/tmp` | Base directory for git clones |
| `LEI_JOBS_PER_CORE_MAX` | `2` | Max concurrent analysis jobs per core |

### Elixir Configuration

Production config in `rel/config/prod.exs`:

```elixir
import Config

config :lei_service, LeiService.Endpoint,
  port: String.to_integer(System.get_env("PORT") || "4000")

config :lei_service,
  cache_ttl: String.to_integer(System.get_env("LEI_CACHE_TTL") || "30"),
  cache_clean_enable: String.to_atom(System.get_env("LEI_CACHE_CLEAN_ENABLE") || "true"),
  default_cache_timeout: 30_000,
  sbom_timeout: 60_000

config :redix,
  redis_url: System.get_env("REDIS_URL") || "redis://localhost:6379/0"
```

## Two HTTP listeners

Production runs **two** HTTP listeners. This is deliberate and neither is
redundant.

| Port | Serves | Entry point for |
|---|---|---|
| 8080 | `LeiService.Endpoint`, with `Lei.Web.Router` mounted inside it | Fly.io (`fly.toml` `internal_port`) |
| 4000 | `Lei.Web.Router` standalone | Kubernetes / Zarf (`apps/lowendinsight/manifests/service.yaml`) |

On Fly the 4000 listener receives no traffic, because only 8080 is routed. **It
is not dead code.** Removing it as part of Fly cleanup would break the UDS
deployment path.

Set `LEI_START_HTTP=false` where only the Fly entry point is needed.

### Routing caveat

`Lei.Web.Router` is only reachable on 8080 for paths listed in `@auth_paths`
(`apps/lei_service/lib/lei_service/endpoint.ex`). A route added to
`Lei.Web.Router` is **unreachable in production until its prefix is added
there**, and returns the endpoint's catch-all 404 instead.

Eight routes were unreachable this way for months, including the whole
`/v1/orgs` provisioning family and every health and metrics endpoint. When
adding a route, add it to `@auth_paths` and to `scripts/smoke-test.sh`.

### Manifest inconsistency

`apps/lei_service/k8s/deployment.yaml` exposes `containerPort: 4444`
while `apps/lei_service/k8s/service.yaml` targets port 4000.
Pre-existing, harmless on Fly, and worth resolving before UDS work resumes.

## Air-Gapped Deployment

LEI supports air-gapped environments through cache export/import.

### Preparing the Cache (Connected Environment)

1. **Warm the cache** by analyzing your dependency list:
   ```bash
   curl -X POST https://lei.example.com/v1/analyze \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"urls": ["https://github.com/org/repo1", ...], "cache_mode": "blocking"}'
   ```

2. **Export the cache**:
   ```bash
   curl -H "Authorization: Bearer $TOKEN" \
     https://lei.example.com/v1/cache/export > lei-cache-export.json
   ```

3. **Transfer** `lei-cache-export.json` to the air-gapped environment.

### Loading Cache (Air-Gapped Environment)

1. **Import the cache**:
   ```bash
   curl -X POST http://lei-local:4000/v1/cache/import \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d @lei-cache-export.json
   ```

2. **Verify import**:
   ```bash
   curl -H "Authorization: Bearer $TOKEN" \
     http://lei-local:4000/v1/cache/stats
   ```

### SBOM-Based Warming

For SBOM-driven environments:

```bash
# Extract URLs from SBOM and warm cache
curl -X POST https://lei.example.com/v1/analyze/sbom \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"sbom\": $(cat sbom.json), \"cache_mode\": \"blocking\", \"cache_timeout\": 300000}"
```

## Monitoring

### Health Checks

- **Liveness**: `GET /` returns 200
- **Readiness**: `GET /v1/cache/stats` returns 200 with valid JSON

### Admin dashboard

`GET /admin` shows cache statistics, expiry distribution, recent requests and
per-org hit/miss counts.

Requires `LEI_ADMIN_TOKEN`. **It fails closed**: if the variable is unset, every
request is denied, so the dashboard is unreachable rather than open. That is the
right default, and it is also why the dashboard silently did not work for months
after it shipped -- the secret was never set. A denial caused by the missing
variable is now logged distinctly, so the two cases are distinguishable to an
operator while looking identical to a caller.

```bash
# Preferred -- keeps the token out of access logs, browser history and Referer
curl -H "Authorization: Bearer $LEI_ADMIN_TOKEN" https://lowendinsight.dev/admin

# Also supported, for browser use
open "https://lowendinsight.dev/admin?token=$LEI_ADMIN_TOKEN"
```

### A green deploy run does not mean a deploy happened

The `deploy` workflow concludes `success` when it **deliberately ships
nothing**. Two merges landing close together finish CI in either order, and
the gate refuses to deploy a commit main has already moved past -- correctly,
since deploying the older one would put production back a version. A workflow
cannot choose its own conclusion, so declining and shipping are identical in
the run list:

```
run 35567530799  657755e  success   <- Deploy and verify: SKIPPED, nothing shipped
run 35552617402  657755e  success   <- Deploy and verify: success, this one shipped
```

The answer is the **`Deploy and verify` job's** conclusion, not the run's:

```bash
scripts/ops/deploy-status.sh            # origin/main
scripts/ops/deploy-status.sh <sha>
```

Exit codes: `0` deployed, `1` not deployed, `2` could not tell. Could not tell
is never reported as deployed.

The run page itself now says which happened, in the job summary -- `SHIPPING`,
`SHIPPED` or `DECLINED` with the reason -- and `run-name` carries the commit
the run was about. Neither changes the run conclusion, which GitHub does not
let a workflow set.

Reading the run conclusion as "deployed" produced two wrong answers in one
sitting on 2026-09-20 before this was written down.

### Deploy canary

`scripts/canary.sh` exercises the journeys the site exists for -- the analyze
form, url validation, trending, the manual, and every local link on the main
page -- against a real deployment. It runs in the deploy gate, where a failure
rolls the release back, and in `monitor.yml` every 15 minutes.

It exists because `GET /url=` hung forever in production while every layer
beneath it was green. The analysis shelled out to `grep` with no file operand,
which searches the working directory under GNU grep and reads stdin under
BusyBox -- and the runtime image is Alpine. It completed in under a second
locally and never returned in production.

Two properties are load-bearing:

**It runs against a deployment.** A suite on a CI runner has GNU grep and tests
an environment that bug cannot exist in.

**It defeats the cache.** `/url=` reads Redis before analysing, with a 30-day
TTL, so a canary analysing the same repository every deploy misses once, goes
green, and then hits cache forever -- staying green while the analysis is
completely broken. It invalidates the entry first, and treats a sub-second
response without invalidation as a failure rather than a pass.

**It reads what is served for secrets.** Every body it fetches -- the home page,
`llms.txt`, a fresh report, trending, `/readyz`, the manual, the OpenAPI spec,
`/metrics`, signup and login -- goes through `scripts/secret-scan.sh`, which
looks for secret-shaped values (Stripe, API and recovery keys, tokens, JWTs,
credentialed database URLs) and for secret setting names. It prints pattern
names, never matched text, and an empty body fails rather than passing.

Reports published the application environment, including Stripe keys and
signing secrets, on these pages for months while every other check was green.

A finding fails the canary, so it **rolls a deploy back** -- including a
finding in data an *earlier* release stored, such as cached reports. If a leak
is found in stored data, purge it before deploying the fix, or the fix will be
rolled back with it. Rotate the exposed secrets either way.

#### The canary's credential

| | |
|---|---|
| GitHub secret | `LEI_ADMIN_API_KEY` |
| Org | `lei-ops` |
| Key name | `deploy-canary` |
| Scope needed | `cache` |

`cache` scope permits the `/v1/cache` family and nothing else. An `admin` key
also works, but grants far more than the job needs -- it can create orgs and
issue further keys, which is more authority than belongs in a CI secret.

To issue or rotate it, run this **in your own terminal**, not through a tool
that echoes output. The key is displayed once and stored hashed; if the second
step fails, issue a new one rather than trying to recover it.

```bash
cat > /tmp/mkkey.exs <<'EOF'
{:ok, org} = Lei.ApiKeys.find_or_create_org("lei-ops", tier: "free", status: "active")
{:ok, raw, key} = Lei.ApiKeys.create_api_key(org, "deploy-canary", ["cache"])
IO.puts(raw)
IO.puts("key_id=#{key.id} org_id=#{org.id}")
EOF

P=$(base64 -w0 < /tmp/mkkey.exs)

flyctl ssh console -a lowendinsight \
  -C "/opt/app/bin/lei_service rpc \"Code.eval_string(Base.decode64!(\\\"$P\\\")) |> elem(0) |> then(fn _ -> :ok end)\"" \
  > /tmp/keyout.txt 2>&1

# key_id and org_id for the record; the key itself stays out of the terminal
grep -v 'lei_' /tmp/keyout.txt

grep -o 'lei_[A-Za-z0-9_-]*' /tmp/keyout.txt | gh secret set LEI_ADMIN_API_KEY
shred -u /tmp/keyout.txt /tmp/mkkey.exs
```

To revoke an old key, list the org's keys and revoke by id:

```elixir
import Ecto.Query
Lei.Repo.all(from(k in Lei.ApiKey, where: k.org_id == <org_id> and k.active == true,
  select: %{id: k.id, name: k.name, scopes: k.scopes, inserted_at: k.inserted_at}))

Lei.ApiKeys.revoke_key(<key_id>)
```

`find_or_create_org/2` is safe here because this is an authenticated operator
action. It is **not** safe on an unauthenticated path that goes on to issue
credentials -- see the warning on that function, and #89.

#### Scopes on endpoint-served routes

`LeiService.Auth` authenticates `/v1` requests and enforces scopes for
routes this endpoint serves itself. `Lei.Auth` does the same for routes
forwarded to `Lei.Web.Router`. Both accept the specific scope **or** `admin`.

A valid JWT is signed with the deployment's own `jwt_secret` and is treated as
operator-level, so it satisfies any scope. API keys are issued to customers and
must carry the scope.

**An operator token must carry `exp`, and it is checked** (`Lei.OperatorToken`,
security review 2026-09-14). Until then both paths called `Joken.verify/2`,
which checks the signature alone: an expired token was accepted, and one minted
without `exp` never expired. Three rules now hold:

- `exp` must be present -- a token without one is refused;
- `exp` must be in the future;
- `exp` must be no more than `:operator_token_max_lifetime_seconds` ahead
  (24 hours by default), so a token cannot be minted today that still works
  next year.

Mint one on the machine, valid for an hour:

```bash
flyctl ssh console -C "/opt/app/bin/lei_service rpc '
  secret = Application.get_env(:lei_service, :jwt_secret)
  signer = Joken.Signer.create(\"HS256\", secret)
  exp = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()
  {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{\"exp\" => exp}, signer)
  IO.puts(jwt)'"
```

A token printed this way is a credential: it is operator-level for as long as
it is valid, so treat it like the signing secret and do not paste it anywhere
it will be kept.

Before this existed, no `/v1/cache` route checked scope in either place: any key
that could call the API could export every cached report, or import over them
and change the answers everyone else received.

### Metrics

Cache statistics available at `GET /v1/cache/stats`:
```json
{
  "total_entries": 1523,
  "by_ecosystem": {"github": 1200, "gitlab": 300},
  "checked_at": "2024-01-15T10:30:00Z"
}
```

### Logging

Logs are written to stdout in Elixir Logger format. Configure level via:
```elixir
config :logger, level: :info  # or :debug, :warning, :error
```

## Scaling

### Horizontal Scaling

LEI-GET is stateless and can be horizontally scaled:
- Multiple instances behind a load balancer
- Shared Redis and PostgreSQL
- Oban handles job coordination automatically

### Resource Recommendations

| Deployment Size | CPU | Memory | Redis | PostgreSQL |
|-----------------|-----|--------|-------|------------|
| Small (< 100 repos) | 1 core | 512MB | 256MB | 256MB |
| Medium (< 1000 repos) | 2 cores | 1GB | 1GB | 512MB |
| Large (> 1000 repos) | 4+ cores | 2GB+ | 2GB+ | 1GB+ |

### Cache Sizing

Approximate cache size per analyzed repo: ~5-10KB

| Repos Cached | Approximate Redis Memory |
|--------------|-------------------------|
| 1,000 | 10MB |
| 10,000 | 100MB |
| 100,000 | 1GB |

## Backup & Recovery

Two independent mechanisms cover different failures. Neither replaces the other.

| Scenario | Volume snapshot | Logical dump |
|---|---|---|
| Machine or volume dies | yes | yes |
| Hosting account lost or compromised | **no** | yes |
| Restore one table or row | no | yes |
| Migrate to another platform | no | yes |
| Detect corruption | no, copies it faithfully | yes, a completed dump proves readability |

### 1. Volume snapshots (primary, Fly deployments)

Automatic daily snapshots of the Postgres volume, 30-day retention.

```bash
flyctl volumes list -a lowendinsight-db
flyctl volumes snapshots list <volume-id> -a lowendinsight-db
flyctl volumes update <volume-id> --snapshot-retention 30 -a lowendinsight-db
```

Retention changes are **not retroactive** -- existing snapshots keep the
retention they were created with, and the longer window builds up over time.

#### Verified restore procedure

Restores into a throwaway volume; production is untouched.

```bash
flyctl volumes create pg_restore_test --snapshot-id <SNAPSHOT_ID> \
  -a lowendinsight-db -r iad -s 1 --yes

flyctl machine run postgres:17-alpine -a lowendinsight-db -r iad \
  -v <NEW_VOL_ID>:/data --vm-memory 512 --rm -- sh -c \
  'export PGDATA=/data/postgresql; chown -R postgres:postgres $PGDATA; chmod 700 $PGDATA;
   su postgres -s /bin/sh -c "pg_ctl -D /data/postgresql -o \"-c shared_preload_libraries=\" -w -t 60 start";
   su postgres -s /bin/sh -c "psql -p 5433 -U postgres -d lei_service_prod -c \"select count(*) from orgs\""'

flyctl volumes destroy <NEW_VOL_ID> -a lowendinsight-db --yes
```

**Two gotchas that cost time if you meet them during an incident:**

1. **A stock Postgres image will not start this data directory.** `postgres-flex`
   sets `shared_preload_libraries = 'repmgr'`, and a plain `postgres:17` image
   fails with `FATAL: could not access file "repmgr"`. Override it as shown above,
   or use the `flyio/postgres-flex` image.
2. **Postgres listens on 5433, not 5432.** `psql` defaults to 5432 and reports
   `No such file or directory` on the socket, which reads exactly like the server
   failed to start when it started fine. Use `psql -p 5433`.

Machine output goes to `flyctl logs`, not stdout.

### 2. Off-platform logical dump (disaster recovery)

**Production takes this backup; CI verifies it.** Since ADR-006 the dump is
produced by a scheduled Fly Machine (`ops/backup/`) inside the same private
network as the database, and `.github/workflows/backup.yml` checks the result
daily.

It changed because producing it in CI put seven external dependencies in the
nightly path -- a third-party action, a flyctl binary resolved as `latest`, the
Fly API, a WireGuard tunnel, `flyctl proxy`, the pgdg apt repository and a
runner. Three nights failed in two weeks from three unrelated causes, and on two
of them the page was rejected with a 401 so nobody was told. Read ADR-006 before
changing any of this.

This exists at all because volume snapshots live in the same hosting account as
the database. Losing that account takes the database and every snapshot with it.

#### The two halves

| | where | what it does |
|---|---|---|
| producer | Fly app `lowendinsight-backup`, scheduled daily | dumps `lowendinsight-db.internal:5432`, verifies the dump is readable, encrypts, uploads to Tigris, writes `meta/latest` last |
| verifier | `backup.yml`, daily 03:30 UTC | fetches the newest object, **fails if it is over 26 hours old**, decrypts, restores into a real PostgreSQL 17 and counts rows |

The freshness limit is the load-bearing check. A scheduled Machine that stops
running -- Fly skipping it, an image that will not boot, a machine someone
destroyed -- produces no red run and no page anywhere. An object that did not
arrive is the only signal, so "the newest backup is 40 hours old" is a build
failure, not a warning.

#### Required secrets

On the **producer** (`flyctl secrets import -a lowendinsight-backup`):

| Secret | Value |
|---|---|
| `PG_DUMP_URL` | `postgres://lei_backup:pass@lowendinsight-db.internal:5432/lei_service_prod` -- the private address; there is no proxy any more |
| `BACKUP_PASSPHRASE` | symmetric encryption key |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Tigris key, **write** scope |

On **GitHub** (`gh secret set`):

| Secret | Value |
|---|---|
| `TIGRIS_READ_ACCESS_KEY_ID` / `TIGRIS_READ_SECRET_ACCESS_KEY` | Tigris key, **read-only** |
| `BACKUP_PASSPHRASE` | the same passphrase the producer encrypts with |

CI no longer holds `PG_DUMP_URL` or any Fly token. It cannot take a backup,
cannot reach the database, and cannot write to the bucket. The credential that
can dump production lives only on the machine that needs it.

`FLY_DB_TOKEN` is no longer used by the backup and can be revoked once the
producer is running. Check nothing else uses it first:
`grep -rn FLY_DB_TOKEN .github/`.

#### Setting it up, or rebuilding it

```bash
./ops/backup/setup.sh          # app, bucket, secrets, scheduled machine
```

Idempotent where Fly allows: an existing app, bucket or secret is left alone.
Re-running it after an incident is the intended way to rebuild the producer. It
never takes a secret as an argument -- everything is read on stdin.

To watch a run, or force one now:

```bash
flyctl machine list -a lowendinsight-backup
flyctl machine start <id> -a lowendinsight-backup
flyctl logs -a lowendinsight-backup
```

The machine runs with `--restart no` on purpose. A failed backup stays failed so
it is noticed; a retry that succeeds hides why the first attempt did not.

#### Blast radius

Tigris is provisioned through Fly and lives in the same organisation as the
database, so **the nightly copy shares a fate with the volume snapshots it
covers for.** Two things carry a copy off Fly:

- the encrypted artifact `backup.yml` uploads on every green run (90 days),
  automatic
- `scripts/backup-pull.sh`, onto a machine you control, manual

The second is not about durability -- the artifact covers that. It is the only
thing that proves the passphrase **you** hold still opens these files, because
CI decrypts with the CI secret and can therefore only establish that CI agrees
with itself. See "Verify backups on a schedule" below.

#### Backup database user

`pg_dump` runs as a dedicated read-only user rather than the application's own
credentials, so the backup job holds no write access and can be revoked
independently.

Connect **to the application database**, not the default `postgres` one --
`GRANT ... ON ALL TABLES` applies only to the database you are connected to, so
running it against `postgres` silently grants nothing useful:

```bash
flyctl postgres connect -a lowendinsight-db -d lei_service_prod
```

```sql
CREATE USER lei_backup WITH PASSWORD '<generated>';
GRANT CONNECT ON DATABASE lei_service_prod TO lei_backup;
GRANT USAGE ON SCHEMA public TO lei_backup;

-- Tables and sequences both. pg_dump reads sequence values to emit setval on
-- restore, so granting tables alone fails with
-- "permission denied for sequence <table>_id_seq".
GRANT SELECT ON ALL TABLES IN SCHEMA public TO lei_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO lei_backup;

-- ON ALL ... affects only objects that exist right now. Without the defaults
-- below, the next migration creates a table or sequence the backup user cannot
-- read, and the job starts failing months later for a reason nobody remembers.
--
-- FOR ROLE is the part that is easy to get wrong, and it is not optional.
-- ALTER DEFAULT PRIVILEGES applies only to objects created by the role that
-- ran it -- which, when you connect with `flyctl postgres connect`, is
-- `postgres`. Migrations run as the application's role, so its new tables
-- inherit nothing and the backup breaks on the next deploy that adds one.
-- This is exactly what happened when credit_entries landed.
--
-- Find the role that actually owns the tables:
--   SELECT tableowner, count(*) FROM pg_tables
--    WHERE schemaname = 'public' GROUP BY 1;
ALTER DEFAULT PRIVILEGES FOR ROLE <table_owner> IN SCHEMA public
  GRANT SELECT ON TABLES TO lei_backup;
ALTER DEFAULT PRIVILEGES FOR ROLE <table_owner> IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO lei_backup;

-- Keep the ownerless form too, for anything created while connected as postgres.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO lei_backup;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO lei_backup;
```

##### When a backup fails with "permission denied for table"

```
pg_dump: error: query failed: ERROR:  permission denied for table credit_entries
```

A migration added a table the backup user cannot read. Re-run the two
`GRANT ... ON ALL` statements above to fix the immediate failure, then the
`ALTER DEFAULT PRIVILEGES FOR ROLE` statements so the next migration does not
do it again.

The backup job fails loudly here rather than archiving a partial dump, which is
the behaviour you want: a backup missing a table is worse than no backup,
because it looks like one.

Verify the grants landed in the right database:

```sql
SELECT count(*) FROM information_schema.table_privileges
 WHERE grantee = 'lei_backup' AND privilege_type = 'SELECT';
```

A count of `0` means they were applied to the wrong database.

A count lower than the number of tables means some are missing. To see which:

```sql
SELECT tablename FROM pg_tables
 WHERE schemaname = 'public'
   AND NOT has_table_privilege('lei_backup', schemaname || '.' || tablename, 'SELECT');
```

An empty result is what you want. Worth running after any deploy that adds a
table, until the default privileges above are confirmed working.

##### Checking the grant contract without touching production

```bash
scripts/verify-backup-grants.sh
```

Creates a throwaway database with the same two-role structure, runs the real
migrations as the application role, applies the grants above, then creates one
more table *after* the grants and dumps as the backup role. That last step is
the one that matters: a check limited to tables that already exist passes
happily while the next migration breaks production.

Runs locally and in CI (`backup-grants` in `umbrella_ci`), needs no Fly access,
and is the only part of the backup path that can be validated without it.

It verifies the **contract**, not production. If production's actual grants have
drifted from what is documented here, only the `has_table_privilege` query above
run against the real database will tell you.

#### Key management

> **GitHub Actions secrets are write-only.** Once `BACKUP_PASSPHRASE` is set it
> cannot be read back through the UI or API. A passphrase that exists only as a
> GitHub secret makes every artifact it encrypts permanently unreadable.

Generate and store the passphrase **before** adding it to GitHub:

```bash
openssl rand -base64 32   # then record it in a password manager
```

Keep it somewhere that is neither the hosting account nor the CI provider. The
threat model is losing the hosting account, so CI holding both artifact and key
is acceptable for that scenario -- but the password manager copy is what makes
the backup recoverable at all.

#### Restore from a dump

```bash
gpg --batch --yes --passphrase "$BACKUP_PASSPHRASE" -d lei-backup.dump.gpg > lei.dump

pg_restore -d <target> lei.dump            # whole database
pg_restore -d <target> -t orgs lei.dump    # single table
pg_restore --list lei.dump                 # inspect without restoring
```

### Verify backups on a schedule

An untested backup is a hypothesis. Both mechanisms should be exercised
periodically, not only when they are needed:

- **After changing `BACKUP_PASSPHRASE`, without exception**, pull a copy off Fly
  and decrypt it with the passphrase from your password manager:

  ```bash
  export BACKUP_PASSCODE='<copy from your password manager>'
  ./scripts/backup-pull.sh                 # newest object in Tigris
  ./scripts/backup-pull.sh --restore       # and restore it into a throwaway PG 17
  ./scripts/backup-pull.sh --keep ~/backups
  ./scripts/backup-pull.sh --list          # what is in the bucket, and the last pull
  ```

  A rotation updates two places -- the producer's Fly secrets and the CI secret
  -- and a rotation that updates one is caught the next night by the verifier's
  decrypt step. A rotation that updates *both* and not your password manager is
  caught by nothing except this script.

  Each pull records its date in `meta/last-local-pull`, and the nightly job
  warns past 30 days. It warns rather than fails because durability does not
  depend on it, and a permanently red backup job stops being read.

  `scripts/verify-backup-artifact.sh` still works and reads a GitHub Actions
  artifact instead of the bucket. Use it when Tigris or Fly is the thing that is
  broken.

  Needs only `gpg` and `gh` -- no PostgreSQL server, and no Postgres client.
  `pg_restore --list` reads the archive file directly and never connects to a
  database; the script uses it when present and falls back to a magic-byte check
  otherwise. The decrypted dump is shredded on every exit path.

  **Use the stored copy, not the GitHub secret.** The backup workflow already
  round-trips every artifact -- encrypting, then decrypting and comparing -- so
  gpg failures and corruption are caught on each run. That check cannot detect
  the failure that matters here: it decrypts with the same secret it encrypted
  with, so a stored copy that has drifted from the GitHub secret still passes.
  Only decrypting with the copy you keep proves the two agree, and that is the
  copy you would reach for when the hosting account is gone.
- **Quarterly**, run the volume restore procedure above and confirm row counts
  against production.

### Redis

Redis holds the analysis cache. It is a performance asset rather than a system
of record -- a cold cache costs money and latency, not data. `/readyz` reports
Redis as an **optional** dependency for this reason: losing it degrades the
service without stopping it.

```bash
curl -H "Authorization: Bearer $TOKEN" \
  https://lei.example.com/v1/cache/export > cache-$(date +%Y%m%d).json
```

## Troubleshooting

### Common Issues

**Redis connection errors** — see the [Redis runbook](#redis-runbook) below.

**Oban job failures**
```
Check PostgreSQL connectivity
Review Oban job logs in oban_jobs table
```

**Analysis timeouts**
```
Increase LEI_JOBS_PER_CORE_MAX for more concurrency
Check git clone performance (network, disk)
Verify LEI_GH_TOKEN is set for GitHub rate limits
```

### Redis runbook

Start here: **`curl -s https://lowendinsight.dev/readyz`**

```json
{"checks":{"redis":"ok","database":"ok"},"status":"ok"}
```

`"redis":"error"` means the app cannot reach Redis. The service keeps serving --
Redis is an optional dependency, so the instance stays in rotation -- but every
analysis is a cache miss, which is slower and, under the ADR-001 pricing model,
bills at ten times the cache-hit rate.

#### Do not reach for a restart first

`%Redix.ConnectionError{reason: :closed}` reads like the server hung up. It does
not mean that. With `sync_connect: false` it is what Redix returns whenever the
background connection has not been established -- it means *"not connected"* and
says nothing about why. Reading it as a server-side close cost two wrong
diagnoses (a GitHub token, then TLS) before the real cause was found.

#### Three failure classes

**1. Transient loss** -- Redis restarted, a network blip, provider maintenance.

**Nothing to do. This recovers on its own.** Redix is configured with
`exit_on_disconnection: false` and retries indefinitely, backing off from 500ms
to a maximum of 30s (defaults, verified against Redix v1.5.3).

Observed in production on 2026-09-11: a disconnect at 03:35:00 had recovered by
03:38, with `beam_uptime_seconds` confirming the process never restarted.
Restarting during this window achieves nothing a few seconds of patience would
not, and drops the in-process batch cache as well.

Expect warnings like `Redis KEYS ... failed: %Redix.ConnectionError{reason: :closed}`
in the logs. Degraded, not broken.

**2. Configuration or credential mismatch** -- retrying never fixes this.

```bash
# What the app believes, from the boot log:
flyctl logs -a lowendinsight --no-tail | grep "Redix opts"
#   host=fly-lei-redis.upstash.io port=6379 db=0 ssl=false socket_opts=[:inet6]

# What the instance actually is:
flyctl redis status lei-redis
```

Compare host, port and scheme. Two specific traps:

- **`socket_opts` must include `:inet6`.** Fly's private network is IPv6-only and
  Redix defaults to IPv4. This exact gap made Redis unreachable for months while
  Postgres -- which had always set `socket_options: [:inet6]` -- worked fine.
- **`ssl` is derived solely from the URL scheme** (`rediss://` vs `redis://`). A
  mismatch closes the connection immediately and looks identical to the server
  rejecting you.

The app reads `REDIS_URL` at boot, so a corrected secret needs a restart --
`flyctl secrets import` does that for you:

```bash
printf 'REDIS_URL=%s\n' "<correct-url>" | flyctl secrets import -a lowendinsight
```

**3. Redis genuinely gone** -- instance deleted, plan suspended, provider outage.

```bash
flyctl redis list
flyctl redis status lei-redis
```

Nothing app-side recovers this. If the instance must be recreated, the cache
starts cold: expensive and slow, but not data loss. Redis holds the analysis
cache, not a system of record.

#### Rotating the credential

```bash
flyctl redis reset lei-redis
printf 'REDIS_URL=%s\n' "<new-url>" | flyctl secrets import -a lowendinsight
curl -s https://lowendinsight.dev/readyz    # expect {"redis":"ok",...}
```

The reset does **not** flush the database; cached entries survive. Do both steps
back to back -- between them the app holds a credential that no longer works.

#### What monitoring will and will not tell you

`.github/workflows/monitor.yml` polls `/readyz` every 15 minutes and fails on
`degraded`, naming the failing dependency. That is the alert.

It will **not** catch a transient blip shorter than the polling interval, and it
should not -- those self-heal. Its purpose is catching the sustained failures in
classes 2 and 3, which are the ones that need a human.

#### When the alert itself is the thing that broke

Every page from this repository -- monitor, deploy and backup -- goes out
through `scripts/notify.sh` to ntfy, authenticated with the `NTFY_TOKEN`
repository secret. A rejected token fails the step that tried to page, which
is visible only if someone is reading the run that already failed for another
reason. On 2026-09-23 and 2026-09-24 the backup failed, `notify.sh` correctly
exited non-zero on an HTTP 401, and nobody was told either night.

The monitor's first step, `Check the alert channel`, now asks ntfy whether the
token is still accepted for the topic, every 15 minutes, without sending a
notification. A 401 or 403 there means no page from anywhere in this
repository is arriving.

```bash
# Rotate: create a new token in the ntfy account, then, over stdin --
# never as a command argument, which would put it in the shell history.
gh secret set NTFY_TOKEN

# Prove the whole path, not just the credential:
gh workflow run notify-test.yml -f message="rotation $(date -u +%F)"
```

`notify-test.yml` is manual and proves the channel at the moment it is run.
The monitor's probe is what keeps it proved.

### Debug Mode

Enable debug logging:
```elixir
config :logger, level: :debug
```

Or via environment:
```bash
LOG_LEVEL=debug ./bin/lei_service foreground
```

## Payment kill switches

Each way payment comes in can be switched off at runtime, without a deploy
(`Lei.Payments.Switches`). This section describes what the mechanism does;
when and how a deployment's operator uses it is a matter for that operator.

| path | switched off |
|---|---|
| `mpp` | no MPP card challenge is offered; a credential for an earlier challenge is refused and not credited (the card is charged only at settlement, so nothing is charged) |
| `tempo` | no stablecoin challenge is offered; a credential is refused and not credited, and **held** (below), because the transfer was made on chain before the credential arrived |
| `acp` | no agent checkout session is opened or completed; the card is charged only at completion |
| `pro_checkout` | no Stripe Checkout is started; a checkout already paid at Stripe is not applied, and its webhook is answered 500 so Stripe retries it once the path is back on |

Refund and dispute events are never switched off.

State is append-only in Postgres (who, when, why); a path with no recorded
change is on, and state that cannot be read is treated as off.

**Changing a switch.** `POST /admin/payments/switches/:path` with
`{"enabled": false, "reason": "...", "actor": "..."}`, authorised by
`LEI_ADMIN_TOKEN` in the `Authorization` header only (a `?token=` query
parameter is refused for changes). `GET /admin/payments/switches` returns the
state. Or, through the release, with verification against `/metrics`:

```bash
scripts/payments.sh switch-off <path> --reason "..." --actor "..."
scripts/payments.sh switch-on  <path> --reason "..." --actor "..."
```

**Visible on `/metrics`:** `lei_payment_switch_enabled{path}` (1 on, 0 off)
and `lei_payment_held{rail}`. The canary skips its stablecoin check only when
`/metrics` reports `tempo` off, so a deploy while it is off is not rolled back
for it.

### Held stablecoin payments

A held payment's challenge and credential are kept from the challenge purge.
`scripts/payments.sh held` lists them. `scripts/payments.sh release
<challenge_id>` verifies the transfer and credits it exactly as a normal
settlement would, with the path still off and after the challenge has expired.
Stripe records a stablecoin payment only once asked to verify it, so a held
payment can be refunded only after it is released.

### Stripe places the account on hold

**Nothing here will tell you.** `/readyz` reports `stripe: ok` throughout:
`Lei.Stripe.ObjectCheck` validates the secret key and the price IDs, and a
held account answers both perfectly well. It does not read account state --
nothing in this codebase does. A hold is therefore invisible to every health
check we have, which is the failure this repository keeps meeting and the
reason this section exists.

What a hold actually stops depends on which one it is, and the two are
independent:

| | effect | what you see here |
|---|---|---|
| `charges_enabled: false` | no new money can be taken | rails refuse; `lei_payment_outcomes{outcome="refused"}` climbs with the Stripe reason |
| `payouts_enabled: false` | money still arrives, none reaches the bank | **nothing at all** -- every metric here is about charges, not payouts |

The second is the dangerous one. Revenue looks healthy, the ledger reconciles,
and the only symptom is money not arriving in the bank -- which no check in
this repository looks at.

**Confirm it, rather than inferring it from failures:**

```bash
stripe get /v1/account | jq '{charges_enabled, payouts_enabled,
  disabled_reason: .requirements.disabled_reason,
  currently_due: .requirements.currently_due,
  past_due: .requirements.past_due}'
```

Healthy looks like `charges_enabled: true`, `payouts_enabled: true`,
`disabled_reason: null`, both requirement lists empty.

**If charges are disabled.** Every rail is taking payment requests it cannot
settle, and an agent presenting a credential gets a refusal after its money has
already moved on chain for the stablecoin rail. Switch the affected paths off
so callers are told the rail is unavailable rather than failing at the wallet:

```bash
scripts/payments.sh switch-off tempo --reason "stripe account hold" --actor "$USER"
scripts/payments.sh switch-off mpp   --reason "stripe account hold" --actor "$USER"
scripts/payments.sh switch-off acp   --reason "stripe account hold" --actor "$USER"
```

Then `scripts/payments.sh held` and release anything stranded once charges are
restored. A switched-off rail is counted on `lei_payment_switch_enabled` and
the monitor fails on it, so this will not be forgotten silently.

**If only payouts are paused**, change nothing. Charges still work, the ledger
is still correct, and switching rails off would refuse money you can accept.

**Restoring.** Stripe lists what it wants under `requirements.currently_due`
and `past_due`; satisfy those in the Dashboard. Re-check with the command
above and switch the rails back on individually, confirming each:

```bash
scripts/payments.sh switch-on tempo --reason "hold cleared" --actor "$USER"
scripts/payments.sh status
```

**Afterwards**, run the reconciliation rather than assuming the gap closed
itself -- a hold that began mid-payment can leave money received and never
credited:

```bash
scripts/payments.sh reconciliation
```

**Known gap.** Because nothing reads account state, the first sign of a hold
will be refusals on `/metrics` or a customer telling you. Adding an account
check to `ObjectCheck` would surface it directly; it is not built, and `payouts_enabled`
would still need somewhere to report to, since no existing gauge covers payouts.

### `scripts/payments.sh`

The command-line interface to these operations (`Lei.Operations`, over `rpc`):
one JSON object on stdout, exit `0` done and verified, `1` refused or not
verified, `2` bad usage, `4` production unreachable. Every change is read back
through a different path than the one that made it, and repeating a command is
safe. `.claude/settings.json` makes the commands that move money prompt before
they run in a Claude Code session.

## Ledger against Stripe

`LeiService.StripeReconciliationWorker` (hourly, Oban cron) compares the
ledger's credit purchases in a recent window with Stripe's PaymentIntents, one
by one, in both directions (`Lei.StripeReconciliation`). A PaymentIntent is a
credit purchase when its metadata carries `challenge_id` (MPP) or `lei_rail`
(agent checkout). Each run is recorded; `scripts/payments.sh reconciliation`
shows the latest.

`/metrics`, from the latest run: `lei_stripe_reconciliation{measure}` with
`runs`, `age_seconds`, `failed`, and -- only when the run did not fail --
`discrepancies`, `ledger_purchases`, `stripe_purchases`.

| discrepancy kind | means |
|---|---|
| `received_not_recorded` | Stripe received a credit purchase the ledger has not credited |
| `missing_in_stripe` | the ledger credited a purchase Stripe has no PaymentIntent for |
| `amount_mismatch` | the ledger credited a different amount than Stripe received |
| `not_succeeded` | the ledger credited a PaymentIntent that has not succeeded |
| `mode_mismatch` | a purchase recorded against the other mode's Stripe |
| `refund_not_recorded` | Stripe refunded more than the ledger reversed |

## Security

### Authentication

- JWT tokens required for all `/v1/*` endpoints
- Configure token signing in `config/prod.exs`

### Network Security

- Run Redis and PostgreSQL on private network
- Use TLS for external API access
- Consider network policies in Kubernetes

### Secrets Management

Required secrets:
- `SECRET_KEY_BASE` - Minimum 64 characters
- `DATABASE_URL` - PostgreSQL credentials. **Required in production** -- the app
  raises at boot if it is unset, rather than falling back to localhost and
  failing confusingly later.
- `LEI_GH_TOKEN` - GitHub API token (optional but recommended)

## Cache Performance

### Performance Benchmarks (2026-02-06)

Tested on localhost with Docker containers (lei-redis, lei-postgres).

#### Cache Hit Latency

| Metric | Value | Target | Status |
|--------|-------|--------|--------|
| Redis PING baseline | 0.38ms avg | - | - |
| Cache stats endpoint | 2.5-3.8ms | <10ms | PASS |
| Cache export (3 entries) | 3.4-4.1ms | <10ms | PASS |
| Cache export (103 entries) | 28-47ms | - | OK |
| Cache import (103 entries) | 32-47ms | - | OK |

#### Concurrent Request Performance

| Test | Requests | Duration | Throughput |
|------|----------|----------|------------|
| Stats endpoint (parallel) | 10 | 5-7ms each | 200+ req/s |
| Export endpoint (parallel) | 5 | 68-72ms each | ~70 req/s |
| Stress test (stats) | 50 | 128ms total | ~390 req/s |

#### Memory Usage

| Entries | Redis Memory | Memory per Entry |
|---------|--------------|------------------|
| 3 | 1.01MB | ~340KB (includes overhead) |
| 103 | 1.29MB | ~3KB/entry |

Redis configuration:
- `maxmemory`: unlimited (default)
- `maxmemory_policy`: noeviction
- Fragmentation ratio: ~10-14x (expected for small datasets)

#### Key Statistics (after stress test)

- Total connections: 260
- Commands processed: 3,490
- Keyspace hits: 2,387 (87%)
- Keyspace misses: 352 (13%)
- Rejected connections: 0

### Performance Recommendations

1. **Cache hit latency is excellent** - well under 10ms target
2. **Export scales linearly** - ~0.3-0.5ms per entry
3. **Import performance is consistent** - ~0.3-0.5ms per entry
4. **No connection rejections** under concurrent load
5. For large caches (>10k entries), consider:
   - Streaming export for memory efficiency
   - Chunked import to avoid timeouts

## Maintenance

### Cache Cleanup

Automatic cleanup runs if `LEI_CACHE_CLEAN_ENABLE=true`. Redis TTL also expires entries.

Manual cleanup:
```bash
redis-cli FLUSHDB  # WARNING: Deletes all cache data
```

### Database Migrations

```bash
mix ecto.migrate
```

### Version Upgrades

1. Pull new image/release
2. Run migrations: `mix ecto.migrate`
3. Rolling restart (if using multiple instances)
4. Verify: `GET /v1/cache/stats`
