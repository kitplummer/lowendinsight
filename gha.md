# Lowendinsight GitHub Action
This is an action for Lowendinsight, a simple "bus-factor" risk analysis library for Open Source Software which is managed by the Georgia Tech Research Institute (GTRI). In its current state, this action works against both NPM and Mix based projects, currently existing in the develop branch of Lowendinsight. When run against a GitHub repository, a `.json` file will be generated of the format `lei--Y-m-d--H-M-S.json` and pushed to that repository's root directory by default.

## Usage

### JSON Report (legacy)
```yaml
name: LEI
on:
  push:
    branches: [ master ]
  pull_request:
    branches: [ master ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v2
    - uses: actions/checkout@master
      with:
        persist-credentials: false # otherwise, the token used is the GITHUB_TOKEN, instead of your personal token
        fetch-depth: 0 # otherwise, you will fail to push refs to dest repo
    - name: Generate Report
      uses: gtri/lowendinsight@gha
      with:
        github_token: ${{ secrets.GITHUB_TOKEN }}
        branch: main
```

### SARIF Output (GitHub Security Tab)

Generate a SARIF 2.1.0 report and upload it to the GitHub Security tab for
display alongside CodeQL and other code scanning results.

```yaml
name: LEI SARIF Scan
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 6 * * 1'  # Weekly Monday 6am UTC

permissions:
  security-events: write
  actions: read
  contents: read

jobs:
  lei-sarif:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Run LowEndInsight SARIF Scan
      uses: gtri/lowendinsight@gha
      with:
        github_token: ${{ secrets.GITHUB_TOKEN }}
        sarif: 'true'
        sarif_file: lei-results.sarif

    - name: Upload SARIF to GitHub Security tab
      uses: github/codeql-action/upload-sarif@v3
      if: always()
      with:
        sarif_file: lei-results.sarif
        category: lowendinsight
```

The SARIF report includes five rule types mapped to LEI risk metrics:

| Rule ID | Name | Description |
| ------- | ---- | ----------- |
| `lei/contributor-risk` | ContributorRisk | Low contributor count indicates bus-factor risk |
| `lei/commit-currency` | CommitCurrencyRisk | Stale dependency has not been committed to recently |
| `lei/functional-contributors` | FunctionalContributorsRisk | Too few active contributors with meaningful commit share |
| `lei/large-recent-commit` | LargeRecentCommitRisk | Last commit changed a large percentage of the codebase |
| `lei/sbom-missing` | SbomRisk | Dependency has elevated SBOM transparency risk |

LEI risk levels map to GitHub severity as follows:

| LEI Risk | SARIF Level | Security Severity |
| -------- | ----------- | ----------------- |
| critical | error | 9.1 |
| high | warning | 7.0 |
| medium | note | 4.5 |
| low | (not reported) | — |

Results point at the project's manifest file (e.g. `mix.exs`, `package.json`)
and use stable fingerprints for deduplication across runs.

## Inputs

| name | value | default | description |
| ---- | ----- | ------- | ----------- |
| github_token | string | | Token for the repo. Can be passed in using `${{ secrets.GITHUB_TOKEN }}`. |
| branch | string | 'master' | Destination branch to push changes (JSON mode only). |
| force | boolean | false | Determines if force push is used (JSON mode only). |
| tags | boolean | false | Determines if `--tags` is used (JSON mode only). |
| directory | string | '.' | Directory to change to before pushing (JSON mode only). |
| repository | string | '' | Repository name. Default or empty value represents current github repository. |
| sarif | boolean | false | Generate SARIF output for GitHub Security tab instead of JSON report. |
| sarif_file | string | 'lei-results.sarif' | Output path for SARIF file (used when `sarif` is `true`). |

## Privacy
This action does not, nor will it ever, collect user data.  Any repository used is Lowendinsight's analysis is cloned and deleted without any information being collected by GTRI nor sent to a third party.
