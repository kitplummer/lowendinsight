# LowEndInsight

[![umbrella_ci](https://github.com/kitplummer/lowendinsight/actions/workflows/elixir.yml/badge.svg?branch=main)](https://github.com/kitplummer/lowendinsight/actions/workflows/elixir.yml) [![Hex.pm](https://img.shields.io/hexpm/v/lowendinsight?include_prereleases)](https://hex.pm/packages/lowendinsight)

## Status: beta (0.16.0-beta.1)

LowEndInsight is in beta. Every published interface carries the pre-release
version: the Hex package, the container image, the Zarf package and UDS
bundle, the REST API (`/openapi.json`, `GET /v1/health`), the web UI (a
banner on every page), the GitHub Action, the [MCP server](apps/lei_service/docs/MCP.md) and the VS Code
extension. Interfaces may change between betas, and breaking
changes are listed in the [CHANGELOG](apps/lowendinsight/CHANGELOG.md).

```elixir
{:lowendinsight, "~> 0.16.0-beta.1"}   # pre-releases need an explicit opt-in
```

<img src="lei_bus_128.png" style="float: left;margin-right: 10px;margin-top: 10px;">

LowEndInsight is a simple "bus-factor" risk analysis library for Open Source Software managed within Git repositories. Provide a git URL, and the library responds with a structured report highlighting potential maintenance and supply-chain risks.

---

## What's New

**Version 0.16.0-beta.1**
- The first beta, including the work prepared as 0.14.0 and 0.15.0, which
  was never published: full clones again, and contributor analysis on large
  repositories goes from minutes to seconds.
- npm lockfileVersion 3 (`package-lock.json` from npm 7+) is parsed;
  scanning a project with one used to crash.
- See [CHANGELOG.md](apps/lowendinsight/CHANGELOG.md).

**Version 0.10.0**
- **Requires Elixir 1.17+** and moves to httpoison 3 / hackney 4, which clears
  four hackney advisories.
- **npm lookups fixed**: `replicate.npmjs.com` answers 404 for every package,
  so npm scans had been analysing bare package names.
- **yarn.lock**: scoped packages keep their names, versions compare as
  versions, and yarn 2+ (berry) lockfiles parse.
- **`Lei.BatchAnalyzer.analyze/2`** takes a `:schedule` function; a miss with
  no scheduler is reported `"uncached"` rather than a job id that names no
  work. `cache_mode: "fresh"` now bypasses the cache.
- See [CHANGELOG.md](apps/lowendinsight/CHANGELOG.md) for the full list, including the hosted
  service's security and background-work changes.

**Version 0.9.1**
- Maintenance and documentation cleanup.
- Standardized project references to GitHub.

**Version 0.9.0**
- **SARIF Output**: Generate SARIF reports for GitHub Security tab integration (`mix lei.sarif`).
- **ZarfGate**: Quality gate for CI/CD pipelines with configurable risk thresholds.
- **AI Rules Generation**: Generate rules for Cursor/GitHub Copilot (`mix lei.generate_rules`).
- **Files Analysis**: Binary file detection, README/LICENSE/CONTRIBUTING presence check.
- **SPDX Parser**: Full SPDX SBOM parsing support.

---

## Why LowEndInsight?

If you are concerned about risks associated with upstream dependency requirements, LowEndInsight provides valuable, actionable information about the likelihood of critical issues being resolved.

- **Single Contributor**: A repo with one contributor isn't necessarily bad, but it carries risk. Are you prepared to fork it if the maintainer disappears?
- **Stale Commits**: If there hasn't been a commit in a significant amount of time, is it stable or just abandoned?
- **Supply Chain**: Vulnerability scanning is only part of the picture. LowEndInsight helps you weigh the human and activity-based risks before you include a dependency.

LowEndInsight provides a simple mechanism for investigating and applying basic governance (based on configurable tolerance levels) and responds with a useful report for integrating into your DevSecOps automation.

---

## Key Metrics

*   **Functional Contributors**: We've found that most projects receive the majority of contributions from one or two people. We report both the total number of contributors and "functional contributors" to identify true bus-factor risk.
*   **Commit Currency**: Many projects are active, while others are dormant. This metric highlights potential supply-chain issues, such as whether a project is staying current with its own upstream dependencies.
*   **SBOM Presence**: Adoption of standard Software Bill of Materials (SBOM) manifests (CycloneDX or SPDX) is often lagging. Lack of an SBOM highlights the need for better provenance and risk management.
*   **Recent Commit Change**: High volatility could indicate instability or high activity. LowEndInsight measures recent change relative to the codebase size to prompt further due diligence.

---

## Installation

[LowEndInsight is available on Hex](https://hex.pm/packages/lowendinsight). Add it to your `mix.exs`:

```elixir
def deps do
  [
    {:lowendinsight, "~> 0.9"}
  ]
end
```

### For Scanning in a Mix-based Project

Add it as a development dependency:

```elixir
defp deps do
  [
    {:lowendinsight, "~> 0.9", only: [:dev, :test], runtime: false}
  ]
end
```

Then run `mix deps.get` and `mix lei.scan`.

---

## Usage

### Scanning Local or Remote Repos

```bash
# Scan a remote repository
mix lei.analyze https://github.com/facebook/react

# Scan a local directory
mix lei.scan /path/to/local/repo
```

### NPM-Based Projects
LowEndInsight can run against NPM projects. It requires an existing `package.json` for first-degree dependencies, and `package-lock.json` for a complete scan including transitive dependencies.

```bash
mix lei.scan /path/to/npm/project
```
*Note: A local installation of Mix is still required.*

### SARIF Output for GitHub Security
Generate SARIF output for integration with GitHub's Security tab:

```bash
mix lei.sarif . --output lei-results.sarif
```

### ZarfGate - Quality Gate for CI/CD
Fail CI pipelines when dependencies exceed risk thresholds:

```bash
# Fail if any dependency has high or critical risk
mix lei.gate . --threshold high
```

### AI Rules Generation
Generate rules for AI coding assistants (Cursor, GitHub Copilot):

```bash
mix lei.generate_rules --target cursor
```

---

## Example Report Output

<details>
<summary>Click to view a full JSON analysis report for React</summary>

```json
{
  "state": "complete",
  "report": {
    "uuid": "caa7f920-aaa3-11ec-9c05-f47b09cc5c9a",
    "repos": [
      {
        "header": {
          "repo": "https://github.com/facebook/react",
          "start_time": "2022-03-23T12:21:13.234974Z",
          "end_time": "2022-03-23T12:21:39.762485Z",
          "duration": 26
        },
        "data": {
          "risk": "medium",
          "results": {
            "contributor_count": 1671,
            "functional_contributors": 97,
            "contributor_risk": "low",
            "commit_currency_weeks": 0,
            "commit_currency_risk": "low",
            "sbom_risk": "medium",
            "large_recent_commit_risk": "low"
          },
          "git": {
            "hash": "de516ca5a635220d0cbe82b8f04003820e3f4072",
            "default_branch": "refs/remotes/origin/main"
          }
        }
      }
    ]
  },
  "metadata": {
    "risk_counts": { "medium": 1 },
    "repo_count": 1
  }
}
```
</details>

---

## Configuration

LowEndInsight allows customization of risk levels. You can set these in your `config/config.exs` or via environment variables.

| Environment Variable | Default | Metric |
| -------------------- | ------- | ------ |
| `LEI_CRITICAL_CURRENCY_LEVEL` | 104 | Weeks since last commit |
| `LEI_CRITICAL_CONTRIBUTOR_LEVEL` | 2 | Minimum discrete contributors |
| `LEI_CRITICAL_LARGE_COMMIT_LEVEL` | 0.40 | Max percentage of codebase changed in a commit |

Example override:
```bash
LEI_CRITICAL_CURRENCY_LEVEL=60 mix lei.scan
```

---

## GitHub Action

Add LowEndInsight to your GitHub workflow:

```yaml
name: LowEndInsight
on: [push, pull_request]

permissions:
  contents: read
  security-events: write

jobs:
  lei:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
      - id: lei
        uses: kitplummer/lowendinsight@v0.16.0-beta.1
      - uses: github/codeql-action/upload-sarif@v4
        with:
          sarif_file: ${{ steps.lei.outputs.sarif_file }}
          category: lowendinsight
```

Inputs, JSON mode and what changed from the old Docker action: [gha.md](gha.md).

---

## Contributing

We welcome contributions! 

- **Bugs?** Report them at [GitHub Issues](https://github.com/kitplummer/lowendinsight/issues).
- **Style**: Run `mix format` before submitting. Documentation for functions is expected.
- **Testing**: Please write ExUnit tests for new code. Use `mix test --cover` to verify coverage.
- **PRs**: Submit atomic pull requests against `main`, after `scripts/preflight.sh` passes.

## License

BSD 3-Clause. See [LICENSE](LICENSE) for details.

Includes code from [mix-deps-json](https://github.com/librariesio/mix-deps-json), Copyright (c) 2016 Andrew Nesbitt, MIT License.

---

## Advanced Usage & Integration

For more specialized use cases, refer to the following:

*   **REST-y API**: A sister project that wraps this library in an HTTP-based interface: [lowendinsight-get](https://github.com/kitplummer/lowendinsight-get).
*   **JSON Schema**: The API schema is available in the `schema/` directory, with documentation in `schema/docs`.
*   **REPL & Docker**:
    *   **IEx**: Run `iex -S mix` and use `AnalyzerModule.analyze/3`.
    *   **Docker**: 
        ```bash
        docker run --rm -v $PWD:/app -w /app -it elixir:latest bash -c "mix local.hex; mix deps.get; iex -S mix"
        ```
*   **Documentation**: Detailed API docs are available via `mix docs` or on [HexDocs](https://hexdocs.pm/lowendinsight/).
