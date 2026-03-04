# Lowendinsight GitHub Action
This is an action for Lowendinsight, a simple "bus-factor" risk analysis library for Open Source Software. In its current state, this action works against both NPM and Mix based projects, currently existing in the develop branch of Lowendinsight. When run against a GitHub repository, a `.json` file will be generated of the format `lei--Y-m-d--H-M-S.json` and pushed to that repository's root directory by default.

## Usage

### JSON Report Mode (Legacy)
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
      uses: kitplummer/lowendinsight@gha
      with:
        github_token: ${{ secrets.GITHUB_TOKEN }}
        branch: main
```

### SARIF Mode (GitHub Security Tab)

Generate a SARIF 2.1.0 report and upload it to the GitHub Security tab for
integrated code scanning alerts.

```yaml
name: LEI Security Scan
on:
  push:
    branches: [ main ]
  pull_request:
    branches: [ main ]
  schedule:
    - cron: '0 6 * * 1'  # Weekly on Monday

permissions:
  security-events: write

jobs:
  lei-sarif:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
      with:
        fetch-depth: 0
    - name: Run LowEndInsight SARIF scan
      uses: kitplummer/lowendinsight@gha
      with:
        sarif: 'true'
        sarif_file: 'lei-results.sarif'
    - name: Upload SARIF to GitHub Security
      uses: github/codeql-action/upload-sarif@v3
      with:
        sarif_file: lei-results.sarif
        category: lowendinsight
```

## Inputs

| name | value | default | description |
| ---- | ----- | ------- | ----------- |
| github_token | string | | Token for the repo. Can be passed in using `${{ secrets.GITHUB_TOKEN }}`. Required for legacy JSON mode. |
| branch | string | 'master' | Destination branch to push changes. Required for legacy JSON mode. |
| force | boolean | false | Determines if force push is used. |
| tags | boolean | false | Determines if `--tags` is used. |
| directory | string | '.' | Directory to change to before pushing. |
| repository | string | '' | Repository name. Default or empty repository name represents current github repository. If you want to push to other repository, you should make a personal access token. |
| sarif | boolean | false | Enable SARIF output mode for GitHub Security tab integration. |
| sarif_file | string | 'lei-results.sarif' | Path to write the SARIF output file (used with `sarif: true`). |

## SARIF Rule Mapping

When using SARIF mode, LowEndInsight risk levels are mapped to GitHub Security
severity levels:

| LEI Risk Level | GitHub Severity | Security Score |
| -------------- | --------------- | -------------- |
| Critical | error | 9.1 |
| High | warning | 7.0 |
| Medium | note | 4.5 |
| Low | (not reported) | 2.0 |

### SARIF Rules

| Rule ID | Description |
| ------- | ----------- |
| `lei/contributor-risk` | Low contributor count indicates bus-factor risk |
| `lei/commit-currency` | Stale dependency has not been committed to recently |
| `lei/functional-contributors` | Too few active contributors with meaningful commit share |
| `lei/large-recent-commit` | Last commit changed a large percentage of the codebase |
| `lei/sbom-missing` | Dependency has elevated SBOM transparency risk |

## Privacy
This action does not, nor will it ever, collect user data. Any repository used in Lowendinsight's analysis is cloned and deleted without any information being collected or sent to a third party.
