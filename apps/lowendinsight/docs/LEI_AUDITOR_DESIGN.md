# LEI Auditor Agent Design

## Overview

The **LEI Auditor** is a new Gas Town agent role responsible for continuous supply-chain risk surveillance. It patrols project manifests, runs LowEndInsight analysis on dependencies, enforces risk thresholds, and escalates findings through the Gas Town hierarchy.

Where existing LEI analysis is point-in-time and user-initiated (`mix lei.analyze`, `mix lei.scan`), the Auditor operates as a persistent, autonomous agent — watching for drift, catching regressions, and keeping the risk ledger current.

**Reference:** See [VIBE_CODING_INTEGRATION.md](./VIBE_CODING_INTEGRATION.md) for the broader AI-integration roadmap that motivates this role.

---

## Agent Taxonomy (Gas Town Roles)

```
+------------------------------------------------------------------+
|                        GAS TOWN ROLES                            |
+------------------------------------------------------------------+
|                                                                  |
|  WITNESS    Observes repository state, records facts             |
|  DEACON     Coordinates workflow, assigns work to roles          |
|  REFINERY   Transforms raw data into risk metrics                |
|  POLECAT    Generates artifacts, executes tasks                  |
|  AUDITOR    Patrols manifests, enforces risk policy   <-- NEW    |
|                                                                  |
+------------------------------------------------------------------+
```

The Auditor combines aspects of Witness (observation), Refinery (analysis), and Polecat (action) into a single patrol-oriented lifecycle. It does not replace those roles — it consumes their capabilities through LEI's existing module API.

---

## Architecture

```
                         ┌─────────────────────┐
                         │     CLI / Config     │
                         │  mix lei.auditor.*   │
                         └────────┬────────────┘
                                  │
                                  ▼
┌──────────────────────────────────────────────────────────────────┐
│                        AUDITOR AGENT                             │
│                                                                  │
│  ┌────────────┐   ┌────────────┐   ┌──────────────┐            │
│  │  Manifest   │──▶│   Patrol    │──▶│  Risk Gate   │            │
│  │  Watcher    │   │   Cycle     │   │  Enforcer    │            │
│  └────────────┘   └────────────┘   └──────┬───────┘            │
│        │                │                  │                     │
│        │ file events    │ analysis         │ violations          │
│        ▼                ▼                  ▼                     │
│  ┌────────────┐   ┌────────────┐   ┌──────────────┐            │
│  │  Manifest   │   │    LEI      │   │  Escalation  │            │
│  │  Registry   │   │  Analyzer   │   │   Engine     │            │
│  └────────────┘   └────────────┘   └──────────────┘            │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
   ProjectIdent        AnalyzerModule        Notifications
   ScannerModule       RiskLogic             (stdout, file,
   Hex/Npm/Pypi        GitModule              webhook, SARIF)
```

### Component Responsibilities

| Component | Module | Responsibility |
|-----------|--------|----------------|
| Manifest Watcher | `Lei.Auditor.Watcher` | Detects changes to dependency manifests via polling or FS events |
| Manifest Registry | `Lei.Auditor.Registry` | Tracks known manifests, last-analyzed hashes, staleness |
| Patrol Cycle | `Lei.Auditor.Patrol` | Orchestrates periodic full-sweep analysis |
| LEI Analyzer | `AnalyzerModule` / `ScannerModule` | Existing analysis engine (unchanged) |
| Risk Gate Enforcer | `Lei.Auditor.Gate` | Compares results against policy thresholds |
| Escalation Engine | `Lei.Auditor.Escalation` | Routes violations to appropriate output channels |

---

## Agent Lifecycle

```
  ┌─────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │  INIT   │────▶│  PATROL  │────▶│ ANALYZE  │────▶│  REPORT  │
  └─────────┘     └────┬─────┘     └──────────┘     └────┬─────┘
       │               │                                   │
       │               │  ┌──────────┐                     │
       │               └──│  WATCH   │◀────────────────────┘
       │                  └──────────┘
       │                       │
       │                       │ on manifest change
       │                       ▼
       │                  ┌──────────┐
       │                  │ RE-AUDIT │──────▶ back to ANALYZE
       │                  └──────────┘
       │
       ▼
  ┌─────────┐
  │  STOP   │
  └─────────┘
```

### States

| State | Description | Transitions |
|-------|-------------|-------------|
| **INIT** | Load config, discover manifests, build registry | -> PATROL |
| **PATROL** | Run scheduled full-sweep analysis of all tracked manifests | -> ANALYZE |
| **ANALYZE** | Invoke LEI analysis on changed or stale dependencies | -> REPORT |
| **REPORT** | Evaluate risk gates, emit findings, update registry | -> WATCH |
| **WATCH** | Idle state monitoring for manifest file changes | -> RE-AUDIT (on change) |
| **RE-AUDIT** | Targeted re-analysis of changed manifests only | -> ANALYZE |
| **STOP** | Graceful shutdown, persist registry state | terminal |

### Process Architecture

The Auditor runs as a supervised GenServer within the application's supervision tree:

```elixir
# In application.ex
children = [
  {Lei.Auditor.Supervisor, auditor_config}
]

# Supervisor starts:
#   - Lei.Auditor.Server (GenServer - patrol loop)
#   - Lei.Auditor.Watcher (file system monitor)
#   - Lei.Auditor.Registry (Agent - manifest state)
```

The GenServer uses `Process.send_after/3` for patrol scheduling, avoiding external scheduler dependencies.

---

## Patrol Cycle

The patrol cycle is the Auditor's core loop. It runs on a configurable interval (default: 1 hour for daemon mode, on-demand for CI).

### Full Patrol

```
1. Registry.list_tracked_manifests()
2. For each manifest:
   a. Compute file hash (SHA-256)
   b. Compare against last-known hash in registry
   c. If changed OR stale (exceeds max_age):
      - Parse manifest -> extract dependency URLs
      - AnalyzerModule.analyze(urls, "auditor", options)
      - RiskLogic evaluation per dependency
      - Gate.check(results, policy)
      - Registry.update(manifest, new_hash, results, timestamp)
3. Escalation.process(all_violations)
4. Schedule next patrol
```

### Incremental Patrol (on file change)

```
1. Watcher detects manifest change event
2. Debounce (2000ms, matching VIBE doc recommendation)
3. Parse changed manifest only
4. Diff dependencies against registry (added, removed, version-changed)
5. Analyze only new/changed dependencies
6. Gate.check + Escalation on violations
7. Registry.update
```

### Staleness Policy

Dependencies are re-analyzed even without manifest changes when their cached analysis exceeds a configurable age. This catches upstream changes (contributor departure, repo archival) that shift risk without local manifest edits.

```
staleness_max_age: 7 days (default)
  - LEI analysis is cached per (dependency_url, analysis_timestamp)
  - Re-analysis triggered when: now - last_analyzed > staleness_max_age
```

---

## Manifest Watching

### Watched Files

The Auditor watches the same manifest set as `ProjectIdent`, extended for lockfiles:

| Ecosystem | Manifests | Lockfiles |
|-----------|-----------|-----------|
| Elixir | `mix.exs` | `mix.lock` |
| Node.js | `package.json` | `package-lock.json`, `yarn.lock` |
| Python | `requirements.txt`, `setup.py`, `pyproject.toml` | `requirements.txt` (is its own lock) |
| Go | `go.mod` | `go.sum` |
| Rust | `Cargo.toml` | `Cargo.lock` |
| Ruby | `Gemfile` | `Gemfile.lock` |
| Java | `pom.xml`, `build.gradle` | — |

### Detection Strategy

Two modes, selected by configuration:

**Polling mode** (default, CI-friendly):
- Scan project tree at patrol interval
- Compute SHA-256 of each manifest
- Compare against registry
- No external dependencies

**FS-event mode** (daemon, optional):
- Uses `file_system` hex package (inotify on Linux, FSEvents on macOS)
- Watches project root recursively with manifest glob filter
- Debounces events (2s window)
- Falls back to polling if FS events unavailable

```elixir
# Configuration
config :lei_auditor,
  watch_mode: :polling,           # :polling | :fs_events
  poll_interval_ms: 3_600_000,    # 1 hour
  debounce_ms: 2_000,
  project_root: "."
```

---

## LEI API Integration

The Auditor consumes LEI's existing analysis API — it does not duplicate analysis logic.

### Analysis Flow

```
  Auditor                          LEI Core
  ───────                          ────────
     │                                │
     │  AnalyzerModule.analyze(       │
     │    urls,                       │
     │    "auditor",          ──────▶ │  Clone repos
     │    start_time,                 │  Run git analysis
     │    %{types: true}              │  Calculate risk
     │  )                             │  Return report
     │                        ◀────── │
     │  ScannerModule.scan(path)      │
     │                        ──────▶ │  Detect project types
     │                                │  Parse manifests
     │                        ◀────── │  Query registries
     │                                │  Analyze each dep
     │                                │
```

### Report Consumption

The Auditor extracts these fields from LEI reports:

```elixir
%{
  repo: url,
  risk: "critical" | "high" | "medium" | "low",
  results: %{
    contributor_count: integer,
    contributor_risk: risk_level,
    commit_currency_weeks: integer,
    commit_currency_risk: risk_level,
    functional_contributors: integer,
    functional_contributors_risk: risk_level,
    large_recent_commit_risk: risk_level,
    recent_commit_size_in_percent_of_codebase: float,
    sbom_risk: risk_level
  }
}
```

### Concurrency

Analysis respects LEI's existing concurrency model:
- `jobs_per_core_max` (default: 2) controls `Task.async_stream` parallelism
- Auditor does not introduce additional concurrency — it delegates to `AnalyzerModule` which handles its own task pool
- Long-running bulk analysis uses the existing `CounterAgent` for progress tracking

---

## Risk Thresholds & Policy

### Default Policy

The Auditor enforces a **policy** — a set of rules that map risk levels to actions. The policy is separate from LEI's risk thresholds (which determine risk *levels*). The policy determines what *happens* at each level.

```elixir
config :lei_auditor,
  policy: %{
    # Gate thresholds: fail the audit if ANY dependency hits this level
    gate_level: :high,              # :critical | :high | :medium | :low

    # Per-dimension overrides (optional, override gate_level for specific risks)
    dimension_gates: %{
      contributor_risk: :critical,           # tolerate high contributor risk
      commit_currency_risk: :high,           # default
      functional_contributors_risk: :high,   # default
      large_recent_commit_risk: :medium,     # stricter on code volatility
      sbom_risk: :low                        # never gate on SBOM alone
    },

    # Allowlist: dependencies exempt from gating (by URL pattern)
    allowlist: [
      ~r|github\.com/elixir-lang/|,
      ~r|github\.com/erlang/|
    ],

    # Max tolerated critical dependencies before hard-fail
    max_critical: 0,
    max_high: 5
  }
```

### Risk Level Hierarchy

```
   LOW          No action. Dependency healthy.
    │
   MEDIUM       Informational. Logged, reported. No gate.
    │
   HIGH         Warning. Logged, reported. Gates if policy says so.
    │
   CRITICAL     Alert. Always logged. Always gates unless allowlisted.
```

### Gate Evaluation

```elixir
defmodule Lei.Auditor.Gate do
  def check(results, policy) do
    violations =
      results
      |> Enum.reject(&allowlisted?(&1, policy.allowlist))
      |> Enum.filter(&violates_gate?(&1, policy))

    critical_count = Enum.count(violations, &(&1.risk == "critical"))
    high_count = Enum.count(violations, &(&1.risk == "high"))

    cond do
      critical_count > policy.max_critical -> {:fail, :critical_exceeded, violations}
      high_count > policy.max_high         -> {:fail, :high_exceeded, violations}
      length(violations) > 0               -> {:warn, violations}
      true                                 -> :pass
    end
  end
end
```

---

## Escalation Rules

Escalation determines how audit findings are communicated. The Auditor supports multiple output channels, activated by severity.

### Escalation Matrix

```
┌───────────┬────────────┬──────────┬──────────┬───────────┐
│  Channel  │  critical  │   high   │  medium  │    low    │
├───────────┼────────────┼──────────┼──────────┼───────────┤
│  stdout   │     ✓      │    ✓     │    ✓     │   (verbose│
│  log file │     ✓      │    ✓     │    ✓     │     ✓     │
│  SARIF    │     ✓      │    ✓     │    ✓     │     -     │
│  webhook  │     ✓      │    ✓     │    -     │     -     │
│  exit code│     1      │    1*    │    0     │     0     │
└───────────┴────────────┴──────────┴──────────┴───────────┘
  * exit code 1 for high only if gate_level is :high or stricter
```

### Output Formats

**Stdout (human-readable):**
```
LEI AUDIT REPORT — 2026-02-06T11:09:00Z
========================================

CRITICAL (1):
  left-pad@1.3.0 (npm)
    contributor_risk: critical (1 contributor)
    commit_currency_risk: critical (312 weeks stale)

HIGH (2):
  some-lib@0.2.1 (hex)
    functional_contributors_risk: high (2 functional contributors)

Gate result: FAIL (1 critical exceeds max_critical=0)
```

**SARIF (GitHub Security tab integration):**
```json
{
  "$schema": "https://raw.githubusercontent.com/oasis-tcs/sarif-spec/main/sarif-2.1/schema/sarif-schema-2.1.0.json",
  "version": "2.1.0",
  "runs": [{
    "tool": { "driver": { "name": "lei-auditor" } },
    "results": [{
      "ruleId": "lei/contributor-risk",
      "level": "error",
      "message": { "text": "left-pad has 1 contributor (critical)" },
      "locations": [{ "physicalLocation": { "artifactLocation": { "uri": "package.json" }}}]
    }]
  }]
}
```

**Webhook (JSON POST):**
```json
{
  "agent": "lei-auditor",
  "timestamp": "2026-02-06T11:09:00Z",
  "gate_result": "fail",
  "violations": [{ "dependency": "left-pad", "risk": "critical", "dimensions": {...} }],
  "summary": { "critical": 1, "high": 2, "medium": 3, "low": 12 }
}
```

### Escalation Configuration

```elixir
config :lei_auditor,
  escalation: %{
    stdout: true,
    log_file: "lei-audit.log",
    sarif_file: nil,                        # set path to enable
    webhook_url: nil,                       # set URL to enable
    webhook_headers: %{},                   # auth headers
    verbose: false                          # include low-risk in stdout
  }
```

---

## CLI Commands

All Auditor commands live under the `lei.auditor` namespace, following the existing `mix lei.*` pattern.

### Command Reference

```
mix lei.auditor.run [OPTIONS]
  Run a single audit patrol and exit.

  --path PATH          Project root to audit (default: ".")
  --format FORMAT      Output format: text, json, sarif (default: text)
  --gate-level LEVEL   Override gate threshold: critical, high, medium, low
  --max-critical N     Max tolerated critical deps (default: 0)
  --max-high N         Max tolerated high deps (default: 5)
  --allowlist PATTERN  Regex pattern to allowlist (repeatable)
  --sarif FILE         Write SARIF output to file
  --verbose            Include low-risk dependencies in output

  Exit codes:
    0  Audit passed (or only medium/low findings)
    1  Audit failed (gate violations)
    2  Auditor error (config, network, etc.)

mix lei.auditor.watch [OPTIONS]
  Start the Auditor in daemon mode with manifest watching.

  --path PATH          Project root to watch (default: ".")
  --poll-interval MS   Polling interval in ms (default: 3600000)
  --watch-mode MODE    Manifest detection: polling, fs_events (default: polling)
  --staleness-days N   Re-analyze after N days without change (default: 7)
  --webhook URL        POST violations to URL
  --log FILE           Write audit log to file

  Runs until interrupted (Ctrl-C). Suitable for development or CI daemon.

mix lei.auditor.status
  Show current Auditor state when running in daemon mode.

  Output:
    - Tracked manifests and their last-analyzed timestamps
    - Current patrol cycle state
    - Recent violations summary
    - Next scheduled patrol time

mix lei.auditor.policy [OPTIONS]
  Display or validate the current audit policy.

  --validate           Check policy config for errors
  --show               Print effective policy (merged config + defaults)
  --export FILE        Export policy as JSON
```

### CI Integration Example

```yaml
# .github/workflows/lei-audit.yml
name: LEI Supply Chain Audit
on:
  pull_request:
    paths:
      - 'mix.exs'
      - 'mix.lock'
      - 'package.json'
      - 'package-lock.json'
      - 'requirements.txt'

jobs:
  audit:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.19'
          otp-version: '27'
      - run: mix deps.get
      - run: mix lei.auditor.run --format sarif --sarif lei-results.sarif
      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: lei-results.sarif
```

---

## Module Structure

```
lib/
├── lei/
│   └── auditor/
│       ├── supervisor.ex       # OTP Supervisor for auditor processes
│       ├── server.ex           # GenServer — patrol loop, state machine
│       ├── watcher.ex          # Manifest file change detection
│       ├── registry.ex         # Agent — tracks manifests and analysis state
│       ├── patrol.ex           # Patrol orchestration logic
│       ├── gate.ex             # Risk policy evaluation
│       ├── escalation.ex       # Output routing (stdout, SARIF, webhook, log)
│       ├── policy.ex           # Policy struct and config parsing
│       └── formatter/
│           ├── text.ex         # Human-readable output
│           ├── json.ex         # JSON output
│           └── sarif.ex        # SARIF 2.1.0 output
├── mix/
│   └── tasks/
│       └── lei/
│           └── auditor/
│               ├── run.ex      # mix lei.auditor.run
│               ├── watch.ex    # mix lei.auditor.watch
│               ├── status.ex   # mix lei.auditor.status
│               └── policy.ex   # mix lei.auditor.policy
```

---

## Data Flow (End-to-End)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                                                                          │
│   mix lei.auditor.run                                                    │
│          │                                                               │
│          ▼                                                               │
│   ┌─────────────┐    ┌────────────────┐    ┌─────────────────────┐      │
│   │  Discover    │───▶│  For each       │───▶│  AnalyzerModule     │      │
│   │  manifests   │    │  manifest:      │    │  .analyze(urls)     │      │
│   │  in project  │    │  parse deps,    │    │                     │      │
│   │  root        │    │  extract URLs   │    │  Returns per-dep    │      │
│   └─────────────┘    └────────────────┘    │  risk report        │      │
│                                             └──────────┬──────────┘      │
│                                                        │                 │
│                                                        ▼                 │
│   ┌─────────────┐    ┌────────────────┐    ┌─────────────────────┐      │
│   │  Escalation  │◀──│  Gate.check    │◀──│  Aggregate results  │      │
│   │  .process()  │    │  (results,     │    │  per manifest,      │      │
│   │              │    │   policy)       │    │  compute rollup     │      │
│   │  stdout /    │    │              │    │  risk                │      │
│   │  SARIF /     │    │  :pass | :warn │    └─────────────────────┘      │
│   │  webhook /   │    │  | :fail       │                                 │
│   │  log         │    └────────────────┘                                 │
│   └─────────────┘                                                        │
│          │                                                               │
│          ▼                                                               │
│   exit code 0 or 1                                                       │
│                                                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Configuration Reference

All configuration lives under `:lei_auditor` in the application environment, overridable via environment variables:

```elixir
config :lei_auditor,
  # Patrol
  poll_interval_ms: 3_600_000,
  staleness_max_days: 7,
  watch_mode: :polling,
  debounce_ms: 2_000,
  project_root: ".",

  # Policy
  gate_level: :high,
  max_critical: 0,
  max_high: 5,
  allowlist: [],
  dimension_gates: %{},

  # Escalation
  stdout: true,
  verbose: false,
  log_file: nil,
  sarif_file: nil,
  webhook_url: nil,
  webhook_headers: %{}
```

Environment variable overrides follow the `LEI_AUDITOR_` prefix convention:

```
LEI_AUDITOR_POLL_INTERVAL_MS
LEI_AUDITOR_STALENESS_MAX_DAYS
LEI_AUDITOR_WATCH_MODE
LEI_AUDITOR_GATE_LEVEL
LEI_AUDITOR_MAX_CRITICAL
LEI_AUDITOR_MAX_HIGH
LEI_AUDITOR_WEBHOOK_URL
LEI_AUDITOR_SARIF_FILE
LEI_AUDITOR_LOG_FILE
LEI_AUDITOR_VERBOSE
```

---

## Implementation Priorities

| Phase | Scope | Dependencies |
|-------|-------|-------------|
| **1. Core patrol** | `Gate`, `Patrol`, `Registry`, `mix lei.auditor.run` | LEI core (existing) |
| **2. Formatters** | Text, JSON, SARIF output | Phase 1 |
| **3. CI integration** | Exit codes, SARIF upload, GitHub Actions example | Phase 2 |
| **4. Watch mode** | `Watcher`, `Server`, `Supervisor`, `mix lei.auditor.watch` | Phase 1 |
| **5. Webhooks** | Escalation webhook channel | Phase 1 |
| **6. MCP bridge** | Expose auditor results via MCP server (see VIBE doc) | Phase 3 |

Phase 1-3 deliver immediate CI/CD value. Phase 4-5 enable developer-loop and ChatOps workflows. Phase 6 connects the Auditor to AI coding assistants via the MCP integration path outlined in [VIBE_CODING_INTEGRATION.md](./VIBE_CODING_INTEGRATION.md).

---

## Open Questions

1. **Registry persistence:** Should the manifest registry persist across auditor restarts (ETS/DETS, JSON file), or rebuild from scratch each run? For CI, rebuild is fine. For daemon mode, persistence avoids redundant re-analysis.

2. **Transitive dependency depth:** Current `ScannerModule.scan/1` analyzes direct dependencies. Should the Auditor walk transitive deps? This significantly increases analysis scope and time.

3. **Rate limiting for registry APIs:** Hex.pm, npm, and PyPI have rate limits. Should the Auditor implement backoff/caching for registry queries during bulk patrol?

4. **Policy-as-code format:** Should policies be expressible as standalone files (`.lei-policy.yml`) for repository-level configuration, or remain in application config only?
