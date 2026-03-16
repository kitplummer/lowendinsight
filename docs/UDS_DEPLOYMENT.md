# UDS Deployment Guide for LowEndInsight

This guide covers deploying LowEndInsight (LEI) using the
[Unicorn Delivery Service (UDS)](https://uds.defenseunicorns.com/) framework
for Kubernetes environments, including air-gapped networks.

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Building from Source](#building-from-source)
- [Configuration](#configuration)
- [Production Deployment](#production-deployment)
- [Air-Gapped Deployment](#air-gapped-deployment)
- [SSO Configuration](#sso-configuration)
- [Monitoring and Observability](#monitoring-and-observability)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)
- [UDS Exemptions](#uds-exemptions)

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| UDS CLI | >= 0.18 | `brew tap defenseunicorns/tap && brew install uds` |
| Docker | >= 24.0 | [docker.com](https://docs.docker.com/get-docker/) |
| k3d | >= 5.6 | `brew install k3d` (local dev only) |
| kubectl | >= 1.28 | `brew install kubectl` |
| jq | any | `brew install jq` (for test scripts) |

**System requirements** (local dev with UDS Core):
- 16 GB RAM minimum (UDS Core + Istio + Keycloak + monitoring stack)
- 4 CPU cores
- 40 GB free disk space

## Quick Start

One-command local deployment:

```bash
# Build image, create Zarf package, create UDS bundle, deploy to k3d
uds run dev
```

This will:
1. Build the LEI production container image
2. Create a Zarf package containing the image
3. Create a UDS bundle with UDS Core + PostgreSQL + LEI
4. Deploy the bundle to a local k3d cluster

Access LEI at: `https://lei.uds.dev`

Verify the deployment:

```bash
uds run test
```

Run the full journey test suite:

```bash
uds run journey-test-only
```

Tear down:

```bash
uds run remove
```

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │              UDS Bundle                  │
                    │                                         │
  Client ──────►   │  Istio Gateway                          │
                    │       │                                 │
                    │       ▼                                 │
                    │  VirtualService (lei.uds.dev)           │
                    │       │                                 │
                    │       ▼                                 │
                    │  ┌─────────────┐    ┌──────────────┐   │
                    │  │  LEI (4000) │───►│  PostgreSQL   │   │
                    │  │             │    │  (Oban jobs,  │   │
                    │  │  Elixir/OTP │    │   API keys,   │   │
                    │  │             │    │   orgs)       │   │
                    │  └─────────────┘    └──────────────┘   │
                    │       │                                 │
                    │       ├──► /healthz, /readyz (probes)   │
                    │       └──► /metrics (Prometheus)        │
                    │                                         │
                    │  ┌─────────────────────────────────┐   │
                    │  │         UDS Core                 │   │
                    │  │  Istio · Keycloak · Pepr         │   │
                    │  │  Prometheus · Grafana · Loki     │   │
                    │  └─────────────────────────────────┘   │
                    └─────────────────────────────────────────┘
```

**Components:**

- **LEI** — Elixir/OTP application serving the batch analysis API on port 4000
- **PostgreSQL** — Stores Oban job queue, API keys, and org data
- **UDS Core** — Provides Istio service mesh, Keycloak SSO, Pepr policy enforcement, and the full monitoring stack (Prometheus, Grafana, Loki, Vector)

**UDS Package CR** — The UDS operator processes the LEI Package custom resource to:
- Create Istio VirtualService routes
- Provision a Keycloak SSO client
- Apply NetworkPolicies
- Register ServiceMonitor for Prometheus scraping

## Building from Source

### Build the container image

```bash
uds run build-image
# or directly:
docker build -f Dockerfile.prod -t ghcr.io/kitplummer/lowendinsight:0.9.1 .
```

### Create the Zarf package

```bash
uds run create-package
# or directly:
uds zarf package create . --confirm --set VERSION=0.9.1
```

### Create the UDS bundle

```bash
uds run create-bundle
# or directly:
uds create . --confirm
```

### Publish to GHCR

```bash
# Zarf package
uds zarf package publish zarf-package-lei-*.tar.zst \
  oci://ghcr.io/kitplummer/packages

# UDS bundle
uds publish uds-bundle-lei-*.tar.zst \
  oci://ghcr.io/kitplummer/bundles
```

### Lint before publishing

```bash
uds run lint
```

## Configuration

Configuration is managed via `uds-config.yaml`. Override values per environment:

```yaml
variables:
  lei:
    LEI_REGISTRY: "ghcr.io/kitplummer"
    LEI_IMAGE_TAG: "0.9.1"
    LEI_HTTP_PORT: "4000"
    LEI_AIRGAPPED_MODE: "false"
    LEI_LOG_LEVEL: "info"

    # Database
    LEI_DB_HOST: "postgresql"
    LEI_DB_PORT: "5432"
    LEI_DB_NAME: "lowendinsight"
    LEI_DB_USER: "postgres"
    LEI_DB_PASSWORD: "change-me"   # Use a secret in production

    # Auth
    LEI_JWT_SECRET: "change-me"    # Use a strong secret in production

  postgresql:
    POSTGRESQL_USERNAME: "postgres"
    POSTGRESQL_PASSWORD: "change-me"
    POSTGRESQL_DATABASE: "lowendinsight"

shared:
  domain: "your-domain.com"        # Your actual domain for production
```

### Key configuration options

| Variable | Default | Description |
|----------|---------|-------------|
| `LEI_REGISTRY` | `ghcr.io/kitplummer` | Container image registry |
| `LEI_IMAGE_TAG` | `latest` | Container image tag |
| `LEI_AIRGAPPED_MODE` | `false` | Disable external network calls |
| `LEI_LOG_LEVEL` | `info` | Log level (debug, info, warn, error) |
| `LEI_JWT_SECRET` | — | JWT signing secret (required) |
| `domain` | `uds.dev` | Base domain for Istio ingress |

## Production Deployment

### Deploy to an existing cluster

1. Create a production `uds-config.yaml` with real values (see [Configuration](#configuration))
2. Ensure your cluster has UDS Core already deployed, or use the full bundle
3. Deploy:

```bash
uds deploy uds-bundle-lei-*.tar.zst --confirm --config uds-config.yaml
```

### TLS certificates

Istio gateways in UDS Core handle TLS termination. To use your own certificates:

```bash
kubectl create secret tls istio-gw-cert \
  -n istio-system \
  --cert=tls.crt \
  --key=tls.key
```

### Resource recommendations

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| LEI | 500m | 512Mi | 2000m | 2Gi |
| PostgreSQL | 250m | 256Mi | 1000m | 1Gi |

## Air-Gapped Deployment

### Transfer workflow

On a **connected** machine:

```bash
# 1. Build everything
uds run create-bundle

# 2. The bundle is a self-contained archive
ls uds-bundle-lei-*.tar.zst
# → uds-bundle-lei-amd64-0.9.1.tar.zst (~2-4 GB with UDS Core)
```

Transfer `uds-bundle-lei-*.tar.zst` and `uds-config.yaml` to the **disconnected** machine via approved media.

On the **disconnected** machine:

```bash
# 3. Deploy (all container images are embedded in the bundle)
uds deploy uds-bundle-lei-*.tar.zst --confirm --config uds-config.yaml
```

### Air-gapped mode

Set `LEI_AIRGAPPED_MODE: "true"` in your `uds-config.yaml`. This disables:
- External git clone operations
- External registry lookups
- Cache refresh from upstream

Analysis will only work against pre-populated cache data.

### Pre-warming the cache

Before building the air-gapped bundle, populate the cache with known dependencies:

```bash
# Analyze your dependency set while still connected
curl -X POST https://lei.yourdomain.com/v1/analyze/batch \
  -H "Authorization: Bearer $LEI_TOKEN" \
  -H "Content-Type: application/json" \
  -d @your-dependencies.json
```

## SSO Configuration

UDS Core includes Keycloak. The LEI Package CR auto-provisions a Keycloak client.

### Default SSO flow

1. User navigates to `https://lei.${DOMAIN}`
2. Istio Authservice redirects to Keycloak login
3. After authentication, Keycloak issues a token
4. Authservice sets a session cookie and proxies the request to LEI
5. LEI receives the request with authentication headers

### User management

Access Keycloak admin console at `https://keycloak.admin.${DOMAIN}`:
- Create users and groups
- Assign roles for LEI access
- Configure external identity providers (LDAP, SAML, OIDC)

### API key authentication

For programmatic access (CI/CD, scripts), use API keys instead of SSO:

```bash
# Create an org
curl -X POST https://lei.${DOMAIN}/v1/orgs \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "my-team"}'

# Generate an API key
curl -X POST https://lei.${DOMAIN}/v1/orgs/my-team/keys \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "ci-key", "scopes": ["analyze"]}'

# Use the API key
curl -X POST https://lei.${DOMAIN}/v1/analyze/batch \
  -H "Authorization: Bearer lei_abc123..." \
  -H "Content-Type: application/json" \
  -d '{"dependencies": [...]}'
```

## Monitoring and Observability

### Grafana dashboards

Access Grafana at `https://grafana.admin.${DOMAIN}`

LEI exposes BEAM VM metrics at `/metrics` in Prometheus exposition format:
- `beam_memory_*` — Erlang VM memory usage
- `beam_process_count` — Active BEAM processes
- `beam_atom_count` — Loaded atoms
- `lei_cache_*` — Cache hit/miss statistics

### Prometheus

ServiceMonitor is auto-configured via the UDS Package CR. Metrics are scraped from the `/metrics` endpoint.

### Logs

Logs are collected via Vector and stored in Loki. Query via Grafana:

```
{namespace="lei"} |= "error"
```

### Health endpoints

| Endpoint | Auth | Purpose |
|----------|------|---------|
| `GET /healthz` | None | Liveness probe — always returns `{"status": "ok"}` |
| `GET /readyz` | None | Readiness probe — checks database connectivity |
| `GET /metrics` | None | Prometheus metrics in exposition format |
| `GET /v1/health` | Required | Application health with cache stats |

## Testing

### Available test tasks

```bash
# Quick validation of a running deployment
uds run test

# Full journey test (build → deploy → validate → cleanup)
uds run journey-test

# Journey test against existing deployment (no build/cleanup)
uds run journey-test-only

# Upgrade test (version N → N+1)
uds run upgrade-test
```

### Journey test checks

The journey test (`tests/journey.sh`) validates 7 aspects:

1. **Pod readiness** — All LEI pods reach Running state
2. **UDS Package CR** — Package CR status is Ready
3. **Istio VirtualService** — Routes are configured correctly
4. **NetworkPolicies** — Network segmentation is enforced
5. **SSO** — Keycloak client secret exists
6. **ServiceMonitor** — Prometheus scraping is configured
7. **API functional tests** — `/healthz`, `/readyz`, `/metrics` respond correctly

### Upgrade test

The upgrade test (`tests/upgrade.sh`) validates:

1. Deploy version N
2. Seed test data
3. Deploy version N+1 over it
4. Verify data preservation (cache, database)
5. Verify functionality post-upgrade
6. Verify upgrade completes within 5 minutes

```bash
bash tests/upgrade.sh previous-bundle.tar.zst current-bundle.tar.zst
```

## Troubleshooting

### Watch Pepr policy enforcement

```bash
uds monitor pepr
```

### Common issues

**Pods stuck in Pending:**
```bash
kubectl describe pod -n lei -l app.kubernetes.io/name=lowendinsight
# Check for resource constraints, image pull errors, or PVC issues
```

**NetworkPolicy blocking traffic:**
```bash
kubectl get networkpolicy -n lei -o yaml
# Verify the policy allows traffic from istio-system
```

**Keycloak client not provisioned:**
```bash
kubectl get package lei -n lei -o yaml
# Check .status.conditions for SSO-related errors
```

**Health check failing:**
```bash
# Check if PostgreSQL is reachable from LEI pod
kubectl exec -n lei deploy/lei -- bin/lei eval "Lei.Repo.query(\"SELECT 1\")"
```

**Image pull errors in air-gapped environment:**
```bash
# Verify the image is included in the Zarf package
uds zarf package inspect zarf-package-lei-*.tar.zst
```

**UDS Core pods consuming too much memory:**
- Minimum 16 GB RAM for local development
- Consider deploying UDS Core slim profile if available
- Reduce Loki retention period

### Debug commands

```bash
# All LEI resources
kubectl get all -n lei

# LEI logs
kubectl logs -n lei -l app.kubernetes.io/name=lowendinsight -f

# UDS Package CR status
kubectl get package -n lei -o wide

# Istio proxy status
istioctl proxy-status

# Pepr policies
kubectl get clusterpolicy -A
```

## UDS Exemptions

LEI may require policy exemptions for git clone operations in non-air-gapped mode. The git clone process needs outbound network access to fetch repository data for analysis.

If Pepr policies block outbound traffic from the LEI namespace:

```yaml
apiVersion: uds.dev/v1alpha1
kind: Exemption
metadata:
  name: lei-git-egress
  namespace: lei
spec:
  exemptions:
    - matcher:
        namespace: lei
        name: "lei-*"
      policies:
        - RequireNonPrivileged
    - matcher:
        namespace: lei
        name: "lei-*"
      policies:
        - RestrictEgress
      description: "LEI requires outbound access for git clone operations"
```

In air-gapped mode (`LEI_AIRGAPPED_MODE: "true"`), this exemption is not needed.

## UDS Runner Tasks Reference

| Task | Description |
|------|-------------|
| `uds run build-image` | Build LEI production container image |
| `uds run create-package` | Create Zarf package |
| `uds run create-bundle` | Build image + Zarf package + UDS bundle |
| `uds run dev` | Full dev workflow: build + deploy to local k3d |
| `uds run deploy` | Deploy bundle to current cluster |
| `uds run remove` | Remove LEI deployment |
| `uds run test` | Quick validation of running deployment |
| `uds run journey-test` | Full lifecycle: build → deploy → test → cleanup |
| `uds run journey-test-only` | Test existing deployment |
| `uds run upgrade-test` | Upgrade validation (N → N+1) |
| `uds run lint` | Lint Zarf package definition |
| `uds run sbom` | Extract SBOM from container |
