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
      - DATABASE_URL=ecto://postgres:postgres@postgres/lowendinsight_get
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
      - POSTGRES_DB=lowendinsight_get
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

config :lowendinsight_get, LowendinsightGet.Endpoint,
  port: String.to_integer(System.get_env("PORT") || "4000")

config :lowendinsight_get,
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
| 8080 | `LowendinsightGet.Endpoint`, with `Lei.Web.Router` mounted inside it | Fly.io (`fly.toml` `internal_port`) |
| 4000 | `Lei.Web.Router` standalone | Kubernetes / Zarf (`apps/lowendinsight/manifests/service.yaml`) |

On Fly the 4000 listener receives no traffic, because only 8080 is routed. **It
is not dead code.** Removing it as part of Fly cleanup would break the UDS
deployment path.

Set `LEI_START_HTTP=false` where only the Fly entry point is needed.

### Routing caveat

`Lei.Web.Router` is only reachable on 8080 for paths listed in `@auth_paths`
(`apps/lowendinsight_get/lib/lowendinsight_get/endpoint.ex`). A route added to
`Lei.Web.Router` is **unreachable in production until its prefix is added
there**, and returns the endpoint's catch-all 404 instead.

Eight routes were unreachable this way for months, including the whole
`/v1/orgs` provisioning family and every health and metrics endpoint. When
adding a route, add it to `@auth_paths` and to `scripts/smoke-test.sh`.

### Manifest inconsistency

`apps/lowendinsight_get/k8s/deployment.yaml` exposes `containerPort: 4444`
while `apps/lowendinsight_get/k8s/service.yaml` targets port 4000.
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
   su postgres -s /bin/sh -c "psql -p 5433 -U postgres -d lowendinsight_get_prod -c \"select count(*) from orgs\""'

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

`.github/workflows/backup.yml` runs daily at 03:30 UTC: `pg_dump` over
`flyctl proxy`, verified with `pg_restore --list`, encrypted with AES256, and
uploaded as a GitHub Actions artifact with 90-day retention.

This exists because volume snapshots live in the same hosting account as the
database. Losing that account takes the database and every snapshot with it.

#### Required secrets

| Secret | Value |
|---|---|
| `PG_DUMP_URL` | `postgres://user:pass@localhost:15432/lowendinsight_get_prod` -- host and port must be `localhost:15432`, where `flyctl proxy` listens |
| `BACKUP_PASSPHRASE` | symmetric encryption key |
| `FLY_DB_TOKEN` | Fly token scoped to the **database** app: `flyctl tokens create deploy -a lowendinsight-db` |

The database runs as a separate Fly app from the application, so the deploy
workflow's `FLY_API_TOKEN` cannot reach it. Widening that token to organisation
scope would fix the proxy while handing every workflow authority over the whole
organisation -- a poor trade for a job whose purpose is surviving an account
compromise. Two narrow tokens are preferred over one broad one.

#### Backup database user

`pg_dump` runs as a dedicated read-only user rather than the application's own
credentials, so the backup job holds no write access and can be revoked
independently.

Connect **to the application database**, not the default `postgres` one --
`GRANT ... ON ALL TABLES` applies only to the database you are connected to, so
running it against `postgres` silently grants nothing useful:

```bash
flyctl postgres connect -a lowendinsight-db -d lowendinsight_get_prod
```

```sql
CREATE USER lei_backup WITH PASSWORD '<generated>';
GRANT CONNECT ON DATABASE lowendinsight_get_prod TO lei_backup;
GRANT USAGE ON SCHEMA public TO lei_backup;

-- Tables and sequences both. pg_dump reads sequence values to emit setval on
-- restore, so granting tables alone fails with
-- "permission denied for sequence <table>_id_seq".
GRANT SELECT ON ALL TABLES IN SCHEMA public TO lei_backup;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO lei_backup;

-- ON ALL ... affects only objects that exist right now. Without these, the next
-- migration creates a table or sequence the backup user cannot read, and the
-- job starts failing months later for a reason nobody remembers.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO lei_backup;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON SEQUENCES TO lei_backup;
```

Verify the grants landed in the right database:

```sql
SELECT count(*) FROM information_schema.table_privileges
 WHERE grantee = 'lei_backup' AND privilege_type = 'SELECT';
```

A count of `0` means they were applied to the wrong database.

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

- **After changing `BACKUP_PASSPHRASE`**, verify an artifact decrypts with the
  copy from your password manager:

  ```bash
  export BACKUP_PASSCODE='<copy from your password manager>'
  ./scripts/verify-backup-artifact.sh              # latest successful backup
  ./scripts/verify-backup-artifact.sh <run-id>     # a specific run
  ```

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

### Debug Mode

Enable debug logging:
```elixir
config :logger, level: :debug
```

Or via environment:
```bash
LOG_LEVEL=debug ./bin/lowendinsight_get foreground
```

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
