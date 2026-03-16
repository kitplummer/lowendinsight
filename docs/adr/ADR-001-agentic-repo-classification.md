# ADR-001: Agentic Repository Classification

## Status

Accepted

## Date

2026-03-14

## Context

LowEndInsight analyzes open-source repositories to help consumers evaluate dependencies. The existing `Lei.AgenticDetector` module classifies individual contributors as `:human`, `:bot`, or `:agent` using email patterns, name patterns, and Co-Authored-By trailers. It currently reports an `agentic_contribution_ratio` (0.0-1.0) and an `agentic_risk` level (low/medium/high/critical) with configurable thresholds.

Agentic development is becoming common. Both human developers and AI agents evaluating dependencies benefit from knowing whether a dependency is human-maintained, agent-assisted, or agent-maintained. This is **not a risk signal** — it is an informational classification that provides transparency.

## Decision

Reframe agentic detection from a risk score to an **informational classification** at the repository level.

### Classification Levels

| Classification | Agentic Ratio | Description |
|---|---|---|
| `human` | < 0.3 | Predominantly human-developed and maintained |
| `mixed` | 0.3 - 0.7 | Significant contributions from both humans and agents |
| `agent` | > 0.7 | Predominantly agent-developed and maintained |

### New Signal: Contributor Access Policy

GitHub repositories can restrict who creates pull requests. When a repo limits PRs to known contributors only, it signals explicit governance over the contribution pipeline. This is fetched via the GitHub API and reported as `restricted_contributors: true|false`.

### API Surface

```json
{
  "agentic_classification": "mixed",
  "agentic_contribution_ratio": 0.45,
  "human_contributor_count": 3,
  "agentic_contributors": ["dependabot[bot]", "Claude"],
  "restricted_contributors": false,
  "agentic_signals": {
    "bot_commits": 12,
    "ai_coauthored_commits": 34,
    "human_commits": 56
  }
}
```

## Work Items

Each item below is an independently implementable unit of work.

### WI-1: Rename agentic_risk to agentic_classification
- **Domain:** eng
- **Priority:** 2
- **Files:** `apps/lowendinsight/lib/lei/agentic_detector.ex`, `apps/lowendinsight/lib/analyzer_module.ex`
- **Description:** Rename the `agentic_risk` field in analysis output to `agentic_classification`. Change values from risk levels (low/medium/high/critical) to classification labels (human/mixed/agent).
- **Acceptance:** `agentic_classification` appears in analysis output; `agentic_risk` removed. All existing tests updated.

### WI-2: Adjust classification thresholds
- **Domain:** eng
- **Priority:** 2
- **Files:** `apps/lowendinsight/lib/lei/agentic_detector.ex`
- **Description:** Change thresholds from risk-oriented (0.5/0.7/0.9) to classification-oriented boundaries: < 0.3 = human, 0.3-0.7 = mixed, > 0.7 = agent.
- **Acceptance:** Threshold constants updated. Detector returns correct classification for ratios at each boundary (0.0, 0.29, 0.3, 0.5, 0.7, 0.71, 1.0).

### WI-3: Add restricted_contributors signal
- **Domain:** eng
- **Priority:** 3
- **Files:** `apps/lowendinsight/lib/lei/agentic_detector.ex`, `apps/lowendinsight/lib/lei/github_api.ex` (new)
- **Description:** Add a GitHub API call to check repository contributor access policy. Report `restricted_contributors: true|false` in the analysis output. When no GitHub token is available, default to `null`. Requires `GET /repos/{owner}/{repo}` endpoint.
- **Acceptance:** Analysis output includes `restricted_contributors` field. Works without token (returns null). Integration test with mock GitHub API.

### WI-4: Deprecate risk-oriented env vars
- **Domain:** eng
- **Priority:** 3
- **Files:** `apps/lowendinsight/lib/lei/agentic_detector.ex`, `apps/lowendinsight/config/config.exs`
- **Description:** Deprecate `LEI_CRITICAL_AGENTIC_LEVEL`, `LEI_HIGH_AGENTIC_LEVEL`, `LEI_MEDIUM_AGENTIC_LEVEL` env vars. Add `LEI_AGENTIC_MIXED_THRESHOLD` (default 0.3) and `LEI_AGENTIC_AGENT_THRESHOLD` (default 0.7). Log a deprecation warning if old vars are set.
- **Acceptance:** New env vars control classification boundaries. Old vars still work but emit deprecation warning. Config documentation updated.

### WI-5: Update tests for new classification
- **Domain:** eng
- **Priority:** 2
- **Files:** `apps/lowendinsight/test/lei/agentic_detector_test.exs`, `apps/lowendinsight/test/analyzer_module_test.exs`
- **Description:** Update all test assertions from `agentic_risk` to `agentic_classification`. Add boundary tests for new thresholds. Add test for `restricted_contributors` field (null when no token, true/false when available).
- **Acceptance:** All tests pass. No references to `agentic_risk` remain in test files. Coverage for new classification labels and threshold boundaries.

## Consequences

- Consumers get a clear, neutral signal about how a dependency is developed.
- The `agentic_risk` -> `agentic_classification` rename is a breaking API change — version appropriately.
- The `restricted_contributors` signal adds an optional GitHub API dependency.
- AI agents selecting dependencies can use classification for informed choices.
