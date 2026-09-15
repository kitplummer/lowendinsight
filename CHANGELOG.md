# Changelog

## 0.9.2 (2026-09-15)

### Security

- **Analysis reports no longer publish the application environment.** Every
  report's `data.config` held `Application.get_all_env(:lowendinsight)`, with
  only `:jobs_per_core_max` removed. Any value an application configured under
  `:lowendinsight` -- an API token, a key, a password, a URL with credentials --
  was published in every report, and in anything that stored or served
  reports. `data.config` now carries only the scoring thresholds
  (`sbom_risk_level` and the `*_contributor_level`, `*_currency_level`,
  `*_large_commit_level` and `*_functional_contributors_level` settings).

  **If you configured anything sensitive under `:lowendinsight`, treat it as
  exposed: rotate it, and discard stored reports.** See the security advisory
  on GitHub for the affected versions.

No other changes from 0.9.1.
