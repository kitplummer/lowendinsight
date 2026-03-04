# LowEndInsight API Reference

LowEndInsight (LEI) provides supply chain security analysis for git repositories. This document covers the REST API endpoints.

## Base URL

Production: `https://your-lei-instance.example.com`
Development: `http://localhost:4000`

## Authentication

All `/v1/*` endpoints require a Bearer token:

```
Authorization: Bearer <your-jwt-token>
```

## Endpoints

### Health Check

#### `GET /`
Returns HTML page. Useful for health checks.

**Response:** `200 OK` with HTML body

---

### Interactive API Documentation

#### `GET /doc`

Serves the Swagger UI, an interactive API explorer for testing endpoints directly from the browser. The UI is loaded from the bundled OpenAPI 3.0 specification.

**Response:** `200 OK` with HTML body (Swagger UI)

No authentication required.

---

#### `GET /openapi.json`

Returns the OpenAPI 3.0 specification for the LowEndInsight API in JSON format. This spec powers the Swagger UI at `/doc` and can be imported into tools like Postman, Insomnia, or used for client code generation.

**Response:** `200 OK` with `application/json` body

**CORS:** The `Access-Control-Allow-Origin: *` header is set, allowing the spec to be fetched from any origin.

No authentication required.

---

### Single/Multiple URL Analysis

#### `POST /v1/analyze`

Analyze one or more git repository URLs.

**Request Body:**
```json
{
  "urls": ["https://github.com/owner/repo"],
  "cache_mode": "blocking",
  "cache_timeout": 30000
}
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `urls` | array | required | List of git repository URLs to analyze |
| `cache_mode` | string | `"blocking"` | How to handle cache misses (see below) |
| `cache_timeout` | integer | `30000` | Timeout in ms for blocking mode |

**Cache Modes:**
- `blocking` - Wait for analysis to complete (up to timeout)
- `async` - Return immediately with job ID, poll for results
- `stale` - Return stale cached data immediately while refreshing in background

**Response (200 OK):**
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "state": "complete",
  "report": {
    "header": {
      "start_time": "2024-01-15T10:30:00Z",
      "end_time": "2024-01-15T10:30:05Z"
    },
    "data": {
      "repo": "https://github.com/owner/repo",
      "results": {
        "risk": "low",
        "contributor_count": 25,
        "functional_contributors": 8,
        "commit_currency_weeks": 2
      }
    }
  }
}
```

**Response (202 Accepted):** Analysis in progress or timed out
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "state": "incomplete",
  "error": "analysis did not complete within 30000ms timeout"
}
```

---

#### `GET /v1/analyze/:uuid`

Retrieve analysis results by job UUID.

**Response (200 OK):** Same as POST response with state "complete"

**Response (404 Not Found):**
```json
{
  "error": "invalid UUID provided, no job found."
}
```

---

#### `GET /v1/job/:id`

Alias for `/v1/analyze/:uuid`. Same behavior.

---

### SBOM Analysis

#### `POST /v1/analyze/sbom`

Analyze all dependencies in a Software Bill of Materials (SBOM).

Supports:
- CycloneDX 1.4+ (JSON)
- SPDX 2.3 (JSON)

**Request Body:**
```json
{
  "sbom": {
    "bomFormat": "CycloneDX",
    "specVersion": "1.4",
    "components": [
      {
        "name": "my-lib",
        "purl": "pkg:github/owner/repo@v1.0.0"
      }
    ]
  },
  "cache_mode": "async",
  "cache_timeout": 60000
}
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `sbom` | object | required | CycloneDX or SPDX JSON object |
| `cache_mode` | string | `"async"` | How to handle cache misses |
| `cache_timeout` | integer | `60000` | Timeout in ms for blocking mode |

**URL Extraction:**
The SBOM parser extracts git URLs from:
- CycloneDX: `externalReferences` (type: vcs), `purl`
- SPDX: `externalRefs` (referenceType: purl/vcs), `downloadLocation`

**Response (200 OK):**
```json
{
  "uuid": "550e8400-e29b-41d4-a716-446655440000",
  "state": "complete",
  "sbom_analysis": true,
  "sbom_urls_found": 42,
  "report": { ... }
}
```

---

### Cache Management

#### `GET /v1/cache/stats`

Get cache statistics.

**Response (200 OK):**
```json
{
  "total_entries": 1523,
  "by_ecosystem": {
    "github": 1200,
    "gitlab": 300,
    "bitbucket": 23
  },
  "checked_at": "2024-01-15T10:30:00Z"
}
```

---

#### `GET /v1/cache/export`

Export entire cache for air-gapped deployment.

**Response (200 OK):**
```json
{
  "entries": [
    {
      "key": "github:owner/repo:latest",
      "data": { ... },
      "ttl_remaining": 2592000
    }
  ],
  "stats": {
    "count": 1523,
    "exported_at": "2024-01-15T10:30:00Z",
    "format_version": "1.0"
  }
}
```

The response includes `Content-Disposition: attachment` header for easy download.

---

#### `POST /v1/cache/import`

Import pre-warmed cache (typically from export).

**Request Body:**
```json
{
  "entries": [
    {
      "key": "github:owner/repo:latest",
      "data": { ... }
    }
  ],
  "overwrite": false,
  "ttl": 2592000
}
```

**Parameters:**
| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `entries` | array | required | Array of cache entries from export |
| `overwrite` | boolean | `false` | Overwrite existing entries |
| `ttl` | integer | config default | TTL in seconds for imported entries |

**Response (200 OK):**
```json
{
  "success": true,
  "stats": {
    "imported": 1500,
    "skipped": 23,
    "errors": 0,
    "total": 1523,
    "imported_at": "2024-01-15T10:35:00Z",
    "ttl_applied": 2592000
  }
}
```

---

### GitHub Trending

LowEndInsight can analyze trending repositories from GitHub, providing risk analysis for popular projects across programming languages. Trending data is fetched from GitHub's daily trending lists and analyzed in bulk.

#### `GET /gh_trending`

List all configured programming languages available for trending analysis. Returns an HTML page.

**Authentication:** None required

**Response:** `200 OK` with HTML body listing languages (e.g. elixir, python, go, rust, java, javascript, ruby, c, c++, c#, haskell, php, scala, swift, objective-c, kotlin, shell, typescript)

**Example:**
```
curl http://localhost:4000/gh_trending
```

---

#### `GET /gh_trending/:language`

View the most recent trending analysis report for a specific language. Returns an HTML page showing the LowEndInsight risk analysis for trending GitHub repositories in that language.

**Authentication:** None required

**Parameters:**
| Parameter | Type | Description |
|-----------|------|-------------|
| `language` | string (path) | Programming language name (e.g. `elixir`, `python`, `rust`) |

**Response:** `200 OK` with HTML report. If no analysis has been run yet, an empty report is displayed.

**Example:**
```
curl http://localhost:4000/gh_trending/elixir
```

---

#### `POST /v1/gh_trending/process`

Trigger a background analysis of trending GitHub repositories for all configured languages. Returns immediately while processing continues asynchronously.

For each language, this endpoint:
1. Fetches the daily trending repositories from GitHub
2. Optionally filters out large repositories (if `LEI_CHECK_REPO_SIZE` is enabled)
3. Runs LowEndInsight analysis on the top N repos (configured via `LEI_NUM_OF_REPOS`, default 10)
4. Stores results in Redis, viewable via `GET /gh_trending/:language`

**Authentication:** Bearer token required

**Response (200 OK):**
```
"Processing languages..."
```

**Example:**
```
curl -X POST http://localhost:4000/v1/gh_trending/process \
  -H "Authorization: Bearer <token>"
```

**Configuration (environment variables):**
| Variable | Default | Description |
|----------|---------|-------------|
| `LEI_NUM_OF_REPOS` | `10` | Number of trending repos to analyze per language |
| `LEI_WAIT_TIME` | `7200000` | Time between processing cycles (ms) |
| `LEI_GH_TOKEN` | (empty) | GitHub API token for repository size queries |
| `LEI_CHECK_REPO_SIZE` | `false` | Filter out repositories larger than 1GB |

---

### URL Validation

#### `GET /validate-url/url=:encoded_url`

Validate if a URL is a valid git repository URL.

**Example:** `GET /validate-url/url=https%3A%2F%2Fgithub.com%2Fowner%2Frepo`

**Response (200 OK):**
```json
{
  "ok": "valid url"
}
```

**Response (201):**
```json
{
  "error": "invalid git url"
}
```

---

## Error Responses

All errors return JSON with an `error` field:

| Status | Meaning |
|--------|---------|
| `401` | Missing or invalid authentication |
| `404` | Resource not found |
| `422` | Invalid request parameters |

```json
{
  "error": "description of the error"
}
```

---

## Rate Limiting

No built-in rate limiting. Implement at the load balancer level for production.

## Cache Key Format

Internal cache keys use the format: `{ecosystem}:{package}:{version}`

Example: `github:owner/repo:latest`

This enables efficient querying and export/import of cached analysis results.
