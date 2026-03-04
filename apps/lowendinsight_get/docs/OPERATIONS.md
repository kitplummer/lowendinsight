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

### Redis Backup

```bash
# RDB snapshot
redis-cli BGSAVE

# Or use cache export endpoint for portable backup
curl -H "Authorization: Bearer $TOKEN" \
  https://lei.example.com/v1/cache/export > backup-$(date +%Y%m%d).json
```

### PostgreSQL Backup

```bash
pg_dump lowendinsight_get > backup-$(date +%Y%m%d).sql
```

## Troubleshooting

### Common Issues

**Redis connection refused**
```
Check REDIS_URL environment variable
Verify Redis is running and accessible
```

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
- `DATABASE_URL` - PostgreSQL credentials
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
