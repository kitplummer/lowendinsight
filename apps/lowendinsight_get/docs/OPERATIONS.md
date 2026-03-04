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

LEI-GET includes first-class UDS integration via a Helm chart, Zarf package, and UDS
Package CR. Infrastructure services (PostgreSQL, Valkey) are deployed as separate
UDS packages in the bundle — this follows the standard UDS convention used by
GitLab, Mattermost, SonarQube, and other UDS applications.

#### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  UDS Core (Istio, Pepr, Keycloak, Monitoring)               │
├──────────┬──────────────┬──────────────┬────────────────────┤
│ lei (ns) │ postgres (ns)│ valkey (ns)  │ istio-system (ns)  │
│          │              │              │                     │
│ lei-get ─┼─▶ pg-cluster │              │ tenant-gateway ◀──┐│
│          │              │              │                    ││
│ lei-get ─┼──────────────┼─▶ valkey     │                    ││
│          │              │   primary    │                    ││
│ lei-get ─┼──────────────┼──────────────┼─▶ HTTPS (443)     ││
│  (git)   │              │              │   (git clone)      ││
│          │              │              │                    ││
│ ◀────────┼──────────────┼──────────────┼── lei.uds.dev ────┘│
└──────────┴──────────────┴──────────────┴────────────────────┘
```

**Key files:**

| File | Purpose |
|------|---------|
| `apps/lowendinsight_get/chart/` | Helm chart for lei-get deployment |
| `zarf.yaml` | Zarf package definition (wraps Helm chart + images + UDS Package CR) |
| `apps/lowendinsight_get/uds-package.yaml` | UDS Package CR (network policies, virtual service, monitoring) |
| `bundle/uds-bundle.yaml` | Development bundle (k3d + UDS Core + postgres + valkey + lei-get) |

#### Prerequisites

- [UDS CLI](https://github.com/defenseunicorns/uds-cli) (`uds` command)
- [Zarf](https://zarf.dev) (`zarf` command)
- Docker (for building images and running k3d)

#### Quick Start (Development Bundle)

The development bundle creates a complete local environment with k3d:

```bash
# 1. Build the Zarf package (from repo root)
zarf package create . --confirm

# 2. Create the UDS bundle
cd bundle
uds create . --confirm

# 3. Deploy everything (k3d cluster, UDS Core, PostgreSQL, Valkey, lei-get)
uds deploy uds-bundle-lei-dev-*.tar.zst --confirm

# 4. Access the app
curl -sk https://lei.uds.dev/
```

The bundle deploys in order:
1. **uds-k3d** — Local k3d cluster with load balancer
2. **init** — Zarf init package (internal registry, agent)
3. **core** — UDS Core (Istio, Pepr operator, monitoring)
4. **postgres-operator** — Zalando PostgreSQL operator + `pg-cluster` instance
5. **valkey** — Valkey (Redis-compatible) with password copied to `lei` namespace
6. **lei-get** — LEI application with Helm chart + UDS Package CR

#### Helm Chart Configuration

The Helm chart is in `apps/lowendinsight_get/chart/` and supports both standalone and UDS deployments.

**Database credentials (Zalando operator):**

When using the Zalando postgres-operator, credentials are auto-generated and stored
in a Kubernetes secret. The chart wires these into the `DATABASE_URL` using
Kubernetes variable substitution:

```yaml
# In bundle overrides or helm install --set:
database:
  existingSecret: "lei.lei.pg-cluster.credentials.postgresql.acid.zalan.do"

# The deployment template constructs DATABASE_URL automatically:
# ecto://$(DB_USERNAME):$(DB_PASSWORD)@pg-cluster.postgres.svc.cluster.local:5432/lowendinsight_get
```

**Valkey credentials (copied secret):**

The UDS valkey package can copy the password to the `lei` namespace. The chart
constructs `REDIS_URL` with proper ACL auth:

```yaml
valkey:
  existingSecret: "lei-valkey-password"

# Produces: redis://default:$(VALKEY_PASSWORD)@valkey-primary.valkey.svc.cluster.local:6379
```

**Key values:**

| Value | Default | Description |
|-------|---------|-------------|
| `fullnameOverride` | `"lei-get"` | Resource name (must match UDS Package CR service name) |
| `image.tag` | `"0.9.3"` | Container image tag |
| `config.port` | `"4000"` | HTTP server port |
| `config.cacheTtl` | `"30"` | Cache TTL in days |
| `config.waitTime` | `"7200000"` | Analysis wait time (ms) |
| `database.existingSecret` | `""` | Zalando operator credentials secret name |
| `valkey.existingSecret` | `""` | Valkey password secret name |
| `secrets.secretKeyBase` | `""` | Secret key for signing (min 64 chars) |
| `secrets.ghToken` | `""` | GitHub API token |

See `apps/lowendinsight_get/chart/values.yaml` for the complete list with descriptions.

#### UDS Package CR

The `apps/lowendinsight_get/uds-package.yaml` defines network policies and service exposure for the UDS
Pepr operator:

- **Ingress**: Exposed via Istio tenant gateway at `lei.<domain>` (port 4000)
- **Egress**: DNS (53), Valkey (6379), PostgreSQL (5432), HTTPS (443 for git clone)
- **Monitoring**: ServiceMonitor on port 4000

#### Bundle Overrides

The bundle wires infrastructure services to lei-get via overrides:

```yaml
# postgres-operator: create database and user, allow ingress from lei namespace
- path: postgresql
  value:
    databases:
      lowendinsight_get: lei.lei
    ingress:
      - remoteNamespace: lei

# valkey: copy password to lei namespace, allow ingress from lei namespace
- path: copyPassword
  value:
    enabled: true
    namespace: lei
    secretName: lei-valkey-password
- path: additionalNetworkAllow
  value:
    - direction: Ingress
      selector:
        app.kubernetes.io/name: valkey
      remoteNamespace: lei
      remoteSelector:
        app.kubernetes.io/name: lowendinsight-get
      port: 6379

# lei-get: use operator-managed secrets
- path: database.existingSecret
  value: "lei.lei.pg-cluster.credentials.postgresql.acid.zalan.do"
- path: valkey.existingSecret
  value: "lei-valkey-password"
```

#### Security Context

The container runs with a hardened security context:
- `readOnlyRootFilesystem: true` — writable paths via emptyDir: `/tmp`, `/opt/app/var`
- `runAsNonRoot: true` (UID 1000)
- All capabilities dropped
- tzdata configured to write to `/tmp/tzdata`

#### Startup Resilience

The application starts the OTP supervisor tree (including the Ecto Repo connection
pool) before running database migrations. Migrations retry up to 10 times with
2-second delays, handling transient connectivity issues common in service mesh
environments (e.g., Istio ambient mode where ztunnel networking takes a moment
to initialize for new pods).

#### Building a Custom Image

```bash
# Build (from repo root)
docker build -f apps/lowendinsight_get/Dockerfile -t ghcr.io/kitplummer/lowendinsight-get:0.9.3-dev .

# Push to Zarf internal registry (for dev cluster testing)
kubectl port-forward svc/zarf-docker-registry -n zarf 5000:5000 &
ZARF_PASS=$(kubectl get secret zarf-state -n zarf -o jsonpath='{.data.state}' \
  | base64 -d | python3 -c "import sys,json; print(json.load(sys.stdin)['registryInfo']['pushPassword'])")
echo "$ZARF_PASS" | docker login localhost:5000 -u zarf-push --password-stdin
docker tag ghcr.io/kitplummer/lowendinsight-get:0.9.3-dev \
  localhost:5000/kitplummer/lowendinsight-get:0.9.3-dev
docker push localhost:5000/kitplummer/lowendinsight-get:0.9.3-dev

# Deploy with Helm
helm upgrade lei-get apps/lowendinsight_get/chart/ -n lei \
  --set image.tag=0.9.3-dev \
  --set database.existingSecret="lei.lei.pg-cluster.credentials.postgresql.acid.zalan.do" \
  --set valkey.existingSecret="lei-valkey-password"
```

#### Teardown

```bash
# Remove the k3d cluster (removes everything)
k3d cluster delete uds
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
