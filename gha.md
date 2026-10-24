# LowEndInsight GitHub Action

> **Beta** (`0.16.0-beta.1`). Inputs and output may change between betas; see
> the [CHANGELOG](apps/lowendinsight/CHANGELOG.md).

Scans a repository's dependencies (Mix, npm, PyPI, Cargo) for bus-factor and
supply-chain risk. The default writes SARIF for GitHub code scanning; JSON mode
writes a report file, and can commit it to a branch.

It is a composite action: it installs Elixir and Erlang with `erlef/setup-beam`
and runs LowEndInsight from this repository at the ref you pin. No Docker. The
first run on a ref compiles for about two minutes; later runs restore from the
Actions cache.

## SARIF (code scanning)

```yaml
name: LowEndInsight
on:
  push:
    branches: [ main ]
  pull_request:
  schedule:
    - cron: '0 6 * * 1'

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

A dependency LowEndInsight cannot analyse is not dropped: it is reported as a
tool notification, which code scanning shows on the tool's status page.

## JSON report

```yaml
      - id: lei
        uses: kitplummer/lowendinsight@v0.16.0-beta.1
        with:
          sarif: 'false'
          directory: reports            # optional; where the file is written
          # To commit the report as well:
          # branch: lei-reports
          # github_token: ${{ secrets.GITHUB_TOKEN }}   # needs contents: write
```

## Inputs

| name | default | description |
| ---- | ------- | ----------- |
| `sarif` | `'true'` | `'true'` writes SARIF; `'false'` writes a JSON report. |
| `sarif_file` | `lei-results.sarif` | SARIF output path, relative to the workspace. |
| `path` | `.` | Directory to scan, relative to the workspace. |
| `directory` | `.` | JSON mode: where the report is written (and committed from). |
| `branch` | | JSON mode: commit the report and push it here. Empty pushes nothing. |
| `github_token` | | JSON mode with `branch`: a token that can push. |
| `repository` | this repository | JSON mode with `branch`: `owner/repo` to push to. |
| `force` | `'false'` | JSON mode with `branch`: force-push. |
| `tags` | `'false'` | JSON mode with `branch`: pass `--tags`. |

## Outputs

| name | description |
| ---- | ----------- |
| `sarif_file` | Absolute path of the SARIF written (SARIF mode). |
| `report_file` | Absolute path of the JSON report written (JSON mode). |

## Changes from the Docker action

The action used to be a Docker action in `apps/lowendinsight/`, referenced as
`kitplummer/lowendinsight@gha`. That ref does not exist, and the image could
not be built after the repository became an umbrella. Two behaviours changed:

- **SARIF is the default.** `sarif: 'false'` gives the JSON report.
- **JSON mode no longer requires a branch.** It writes the file; it pushes only
  when `branch` is set.

## SARIF rule mapping

| LEI risk | Code scanning level | security-severity |
| -------- | ------------------- | ----------------- |
| Critical | error | 9.1 |
| High | warning | 7.0 |
| Medium | note | 4.5 |
| Low | not reported | 2.0 |

| Rule ID | Description |
| ------- | ----------- |
| `lei/contributor-risk` | Low contributor count indicates bus-factor risk |
| `lei/commit-currency` | Stale dependency has not been committed to recently |
| `lei/functional-contributors` | Too few active contributors with meaningful commit share |
| `lei/large-recent-commit` | Last commit changed a large percentage of the codebase |
| `lei/sbom-missing` | Dependency has elevated SBOM transparency risk |

## Privacy

The action collects nothing. Each dependency's repository is cloned to the
runner's temporary directory, analysed, and deleted.
