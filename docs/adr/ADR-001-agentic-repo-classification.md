# ADR-001: Agentic Repository Classification

## Status

Accepted

## Date

2026-03-14

## Context

LowEndInsight analyzes open-source repositories to help consumers evaluate dependencies. The existing `Lei.AgenticDetector` module classifies individual contributors as `:human`, `:bot`, or `:agent` using:

- **Email patterns**: dependabot@, renovate@, github-actions@, etc.
- **Name patterns**: names containing `[bot]`
- **Co-Authored-By trailers**: Claude, Copilot, Cursor, GitHub Copilot

It currently reports an `agentic_contribution_ratio` (0.0–1.0) and an `agentic_risk` level (low/medium/high/critical) with configurable thresholds.

Agentic development is becoming common. Repositories are increasingly maintained, partially or fully, by AI agents — from automated dependency updates (Dependabot, Renovate) to full implementation workflows (Claude Code, Cursor, Copilot). Both human developers and AI agents evaluating dependencies benefit from knowing whether a dependency is human-maintained, agent-assisted, or agent-maintained.

Additionally, GitHub now exposes repository settings that indicate **contributor access policies** — specifically, whether a repository restricts pull request creation to known contributors only. This is a governance signal that strengthens classification confidence: a repo that limits PRs to known contributors has explicit human oversight of who can contribute, regardless of whether those contributors use AI tooling.

This is **not a risk signal**. A repository maintained by agents is not inherently riskier or safer than one maintained by humans. It is an informational classification that provides transparency into how a project is developed and maintained.

## Decision

Reframe agentic detection from a risk score to an **informational classification** at the repository level.

### Classification Levels

| Classification | Agentic Ratio | Description |
|---|---|---|
| `human` | < 0.3 | Predominantly human-developed and maintained |
| `mixed` | 0.3 – 0.7 | Significant contributions from both humans and agents |
| `agent` | > 0.7 | Predominantly agent-developed and maintained |

### New Signal: Contributor Access Policy

GitHub repositories can restrict who is allowed to create pull requests. When a repo limits PRs to known contributors only, it signals explicit governance over the contribution pipeline. This is relevant to agentic classification because:

- A repo with **open PRs + high agentic ratio** may be passively accumulating bot/agent contributions without oversight.
- A repo with **restricted PRs + high agentic ratio** has deliberately chosen to include agents as known contributors — an intentional development model choice.

This signal is fetched via the GitHub API (`GET /repos/{owner}/{repo}` — the `allow_forking` and contributor restriction settings) and reported as `restricted_contributors: true|false`.

### API Surface

The analysis report will include:

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

### What Changes

1. **Rename `agentic_risk` to `agentic_classification`** in the analysis output. The field value changes from risk levels (low/medium/high/critical) to classification labels (human/mixed/agent).

2. **Adjust thresholds** from risk-oriented (0.5/0.7/0.9) to classification-oriented (0.3/0.7) boundaries. The current thresholds cluster around high ratios because they were designed to flag risk; the new boundaries distribute more evenly across the spectrum.

3. **Retain `agentic_contribution_ratio`** as-is. It remains a useful raw metric.

4. **Deprecate risk-oriented env vars** (`LEI_CRITICAL_AGENTIC_LEVEL`, `LEI_HIGH_AGENTIC_LEVEL`, `LEI_MEDIUM_AGENTIC_LEVEL`) in favor of `LEI_AGENTIC_MIXED_THRESHOLD` and `LEI_AGENTIC_AGENT_THRESHOLD`.

5. **Add `restricted_contributors` signal** from the GitHub API. Reports whether the repository limits PR creation to known contributors only. Requires a GitHub token for API access; when unavailable, the field defaults to `null`.

### What Stays the Same

- The `AgenticDetector` module's contributor-level classification (`:human`, `:bot`, `:agent`) is unchanged.
- Detection heuristics (email patterns, name patterns, Co-Authored-By trailers) are unchanged.
- The ratio calculation is unchanged.

## Consequences

- Consumers of LEI analysis — both humans and AI agents — get a clear, neutral signal about how a dependency is developed, without the loaded framing of "risk."
- AI agents selecting dependencies can use this classification to make informed choices (e.g., preferring agent-maintained dependencies for compatibility, or preferring human-maintained ones for certain trust models).
- Human developers gain transparency into the development model of their dependency tree.
- The existing `agentic_risk` field in analysis output becomes `agentic_classification`, which is a breaking change for API consumers. This should be versioned appropriately.
- The `restricted_contributors` signal adds context that commit-based heuristics alone cannot provide — it distinguishes intentional agent inclusion from passive accumulation. This requires GitHub API access (authenticated for private repos), adding an optional external dependency to the analysis pipeline.
