# LEI Test Suite Audit

**Date:** 2026-02-07
**Auditor:** lei/polecats/rust
**Bead:** lei-0sg
**Total test files:** 26 (+ test_helper.exs + support/fixture_helper.ex)
**Total tests:** 97 tests + 13 doctests = 110
**Excluded by default:** 57 (tagged `:long` and/or `:network`)
**Run by default:** 53 (40 tests + 13 doctests)

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Test Infrastructure](#test-infrastructure)
3. [Test File Audit](#test-file-audit)
4. [Flakiness Sources](#flakiness-sources)
5. [Determinism Recommendations](#determinism-recommendations)

---

## Executive Summary

The LEI test suite has **significant determinism issues**. Over half the tests (57/110) are excluded by default because they require network access to clone GitHub/GitLab/Bitbucket repos. The tests that do run locally have one consistent failure (`SbomModuleTest.has_spdx?`) due to CWD/git-worktree sensitivity.

**Key findings:**
- **57 tests excluded by default** — massive untested surface in CI
- **Network-dependent tests** clone live repos (GitHub, GitLab, Bitbucket) making them inherently flaky
- **Hardcoded expected values** (commit counts, contributor lists) will break as upstream repos change
- **CWD-relative file paths** (`./test/fixtures/...`, `./mix.lock`) cause failures in non-standard execution contexts
- **No mocking infrastructure used** — `Mox` is configured but unused by any test
- **Fixture repos exist** (`test/support/fixture_helper.ex`) but are not used by any test
- **1 consistent failure**: `SbomModuleTest.has_spdx?` fails when CWD is a git worktree

---

## Test Infrastructure

### test_helper.exs
- Configures ExUnit with environment-based exclusions
- CI: excludes both `:network` and `:long` tags
- Local: excludes only `:long` tag
- Compiles `test/support/fixture_helper.ex`
- Defines `GitModule.Mock` via Mox (for `GitModule.Behaviour`) — **but no test uses it**

### Fixture Files (test/fixtures/)
| File | Used By | Description |
|------|---------|-------------|
| `lockfile` | LockfileTest, EncoderTest | Sample mix.lock (6 deps) |
| `mixfile` | MixfileTest, EncoderTest | Sample mix.exs deps section |
| `packagejson` | PackageJSONTest, ScanTest | Sample package.json |
| `package-lockjson` | PackageJSONTest, ScanTest | Sample package-lock.json |
| `yarnlock` | YarnlockTest, ScanTest | Sample yarn.lock |
| `yarnlock_v2` | **(unused)** | Yarn v2 lock file |
| `requirementstxt` | ScanTest | Python requirements.txt |
| `npm.short.csv` | BulkAnalyzeTest | CSV of npm package URLs |
| `cargotoml` | CargofileTest | Sample Cargo.toml |
| `cargolock` | CargolockTest | Sample Cargo.lock |
| `repos/setup_fixtures.sh` | FixtureHelper | Script to create deterministic git repos |

### Support Files
| File | Status | Description |
|------|--------|-------------|
| `support/fixture_helper.ex` | **Unused** | Provides deterministic fixture git repos (simple_repo, multi_contributor_repo, etc.) |

### Mox Configuration
| Mock | Status | Description |
|------|--------|-------------|
| `GitModule.Mock` | **Unused** | Defined for `GitModule.Behaviour` but no test uses it |

---

## Test File Audit

### 1. test/analyzer_test.exs — AnalyzerTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | analyze local path repo | unit | `network: false, long: false` | None (uses CWD) | LOW — CWD must be a git repo |
| 2 | get empty report | unit | `network: false, long: false` | None | NONE |
| 3 | get report | e2e | `@moduletag :network, :long` | `github.com/kitplummer/xmpp4rails` | HIGH — clones repo, hardcoded contributor data |
| 4 | get multi report mixed risks | e2e | `:long` | `github.com/kitplummer/xmpp4rails`, `github.com/robbyrussell/oh-my-zsh` | HIGH — network + hardcoded risk counts |
| 5 | get multi report for dot named repo | e2e | (module tags) | `github.com/satori/go.uuid` | HIGH — network, repo may be deleted |
| 6 | get multi report mixed risks and bad repo | e2e | (module tags) | `github.com/kitplummer/xmpp4rails`, `github.com/kitplummer/blah` | MEDIUM — tests error case |
| 7 | analyze a repo with a single commit | e2e | (module tags) | `github.com/shadowsocks/shadowsocks` | HIGH — censored repo, unpredictable |
| 8 | analyze a repo with a dot in the url | e2e | (module tags) | `github.com/satori/go.uuid` | HIGH — archived repo risk |
| 9 | input of optional start time | e2e | (module tags) | `github.com/hmfng/modal.git` | HIGH — small personal repo, may be deleted |
| 10 | get report fail | e2e | (module tags) | `github.com/kitplummer/blah` | MEDIUM — tests 404 case |
| 11 | get report when subdirectory and valid | e2e | (module tags) | `gitlab.com/lowendinsight/test/pymodule` | HIGH — GitLab availability |
| 12 | get report fail when subdirectory and not valid | e2e | (module tags) | `github.com/kitplummer/xmpp4rails/blah` | MEDIUM — tests error case |
| 13 | get single repo report validated by report schema | e2e | `:long` | `github.com/kitplummer/lita-cron` | HIGH — network + schema validation |
| 14 | get multi repo report validated by report schema | e2e | `:long` | `github.com/kitplummer/xmpp4rails`, `github.com/kitplummer/lita-cron` | HIGH — network |
| - | doctest AnalyzerModule | unit | (module tags) | None | NONE |

**setup_all:** Clones `kitplummer/xmpp4rails` into temp dir to extract last commit date. Runs for ALL tests in module even local ones (but uses `context[:weeks]` only in "get report").

**Flakiness sources:**
- `setup_all` clones a remote repo — if GitHub is down, ALL tests fail
- Hardcoded contributor data (names, counts, emails) will break if upstream repos change
- `go.uuid` repo (satori) is archived and may be deleted
- `shadowsocks/shadowsocks` is a censored repo — unpredictable availability

---

### 2. test/files_test.exs — FilesTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | analyze files in path repo | e2e | `@moduletag :network, :long` | `github.com/kitplummer/xmpp4rails` | HIGH — hardcoded file counts (15 files) |
| 2 | analyze files in elixir repo | e2e | (module tags) | `github.com/kitplummer/lowendinsight` | HIGH — hardcoded file counts (178 files), binary file names |

**Flakiness sources:**
- Hardcoded `total_file_count: 178` — breaks when any file is added to upstream repo
- Hardcoded `binary_files: ["lei_bus_128.png"]` — breaks if image renamed

---

### 3. test/git_helper_test.exs — GitHelperTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-7 | Various parse_header tests | unit | `:helper` | None | NONE |

**Assessment:** Fully deterministic. Pure parsing tests with inline fixture data. Exemplary test design.

---

### 4. test/git_module_test.exs — GitModuleTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | get current hash | integration | `@moduletag :network, :long` | `github.com/kitplummer/xmpp4rails` | HIGH — hardcoded hash |
| 2 | get default branch | integration | (module tags) | (same repo) | MEDIUM — branch name may change |
| 3 | get commit count for default branch | integration | (module tags) | (same repo) | HIGH — hardcoded count: 7 |
| 4 | get commit count for default branch for path | integration | (module tags) | CWD repo | MEDIUM — depends on local repo state |
| 5 | get contributor list 1 | integration | (module tags) | (same repo) | HIGH — hardcoded: 1 |
| 6 | get contributor list 3 | integration | (module tags) | `github.com/kitplummer/lita-cron` | HIGH — hardcoded: 4 |
| 7 | get contribution maps | integration | (module tags) | `github.com/kitplummer/kit` | HIGH — hardcoded contribution counts |
| 8 | get cleaned contribution map | integration | (module tags) | (same repo) | HIGH — hardcoded emails, merge counts |
| 9 | get commit dates | integration | (module tags) | `github.com/kitplummer/xmpp4rails` | HIGH — hardcoded epoch timestamps |
| 10 | get last commit date | integration | (module tags) | (same repo) | HIGH — hardcoded date string |
| 11 | get last contribution by contributor date | integration | (module tags) | (same repo) | HIGH — hardcoded date |
| 12 | convert to delta | integration | (module tags) | (same repo) | LOW — uses `>=` comparison |
| 13 | get commit and tag dates | integration | (module tags) | `github.com/kitplummer/libconfuse` | HIGH — hardcoded diffs array |
| 14 | get code changes in last 2 commits | integration | (module tags) | Multiple repos | HIGH — hardcoded diff stats |
| 15 | get contributor counts | integration | (module tags) | Multiple repos | HIGH — hardcoded map values |
| 16 | get the number of contributors over a certain percentage | integration | (module tags) | Multiple repos | HIGH — hardcoded counts |
| 17 | get local path repo | unit | `network: false, long: false` | None (CWD) | LOW — CWD must be git repo |
| 18 | error on not a valid local path repo | unit | `network: false, long: false` | None (/tmp) | NONE |
| 19 | get repo size | integration | (module tags) | (cloned repo) | LOW — nil/empty check only |
| 20 | subgroup repo from gitlab | integration | (module tags) | `gitlab.com/lowendinsight/test/pymodule` | LOW — nil check only |
| 21 | repo with a no name committer | unit | `network: false, long: false` | None | NONE |

**setup_all:** Clones **6 remote repos** (GitHub, Bitbucket, GitLab). This is the most network-heavy test module.

**Flakiness sources:**
- Clones from GitHub, Bitbucket, AND GitLab — triple points of failure
- Massive hardcoded expected values (exact timestamps, contributor counts, emails)
- Any new commit to upstream repos breaks multiple tests

---

### 5. test/helpers_test.exs — Lowendinsight.HelpersTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | converter works? | unit | None | None | NONE |
| 2 | validate path url | unit | None | None (CWD) | LOW — uses `File.cwd()` |
| 3 | validate urls | unit | None | None | NONE |
| 4 | validate scheme | unit | None | None | NONE |
| 5 | removes git+ prefix | unit | None | None | NONE |
| - | 11 doctests | unit | None | None | NONE |

**Assessment:** Fully deterministic. `async: true`. Good test design.

---

### 6. test/hex/encoder_test.exs — Lowendinsight.Hex.EncoderTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | encoder works for mix.exs | unit | None | `./test/fixtures/mixfile` | MEDIUM — CWD-relative path |
| 2 | encoder works for mix.lock | unit | None | `./test/fixtures/lockfile` | MEDIUM — CWD-relative path |
| 3 | get dependency tree as json | unit | None | `./test/fixtures/lockfile` | MEDIUM — CWD-relative path |
| 4 | get mix.lock dependency tree as json | unit | None | `./mix.lock` | HIGH — reads project's own mix.lock, hardcoded expected "bunt" |

**Flakiness sources:**
- All paths are CWD-relative (`./test/fixtures/...`, `./mix.lock`)
- Test 4 reads the actual project `mix.lock` and asserts `"bunt"` is the first dependency — breaks if mix.lock order changes

---

### 7. test/hex/lockfile_test.exs — LockfileTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts dependencies from mix.lock | unit | None | `./test/fixtures/lockfile` | MEDIUM — CWD-relative path |

**Assessment:** Deterministic if CWD is correct. Uses fixture data.

---

### 8. test/hex/mixfile_test.exs — MixfileTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts dependencies from mix.exs | unit | None | `./test/fixtures/mixfile` | MEDIUM — CWD-relative path |

**Assessment:** Deterministic if CWD is correct. Uses fixture data.

---

### 9. test/mix_analyze_test.exs — Mix.Tasks.AnalyzeTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | run analysis, validate report, return report | e2e | `:long, :network` | 6 remote repos | CRITICAL — any deletion/rename breaks test |

**Flakiness sources:**
- Clones 6 different repos in a single test (expressjs/express, kitplummer/blah, amorphid/artifactory-elixir, wli0503/Mixeur, betesy/201601betesy_test, gitlab.com/lowendinsight/test/pymodule)
- Several are small personal repos that may be deleted at any time

---

### 10. test/mix_bulk_analyze_test.exs — Mix.Tasks.BulkAnalyzeTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | run scan, validate report | e2e | `:long, :network` | URLs in `test/scan_list_test` | HIGH |
| 2 | run scan against NPM cleaned list | e2e | `:long, :network` | URLs in `test/fixtures/npm.short.csv` | HIGH — 10 npm repos |
| 3 | run scan against non-existent file | unit | `:long` | None | NONE |
| 4 | run scan against invalid file | unit | `:long` | None | NONE |

---

### 11. test/mix_dependencies_test.exs — Mix.Tasks.DependenciesTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | should fail with valid message | unit | None | None | NONE |
| 2 | run scan and report against no args local | unit | None | `./mix.lock` | MEDIUM — expects "bunt" first |
| 3 | run scan and report against given local | unit | None | `./mix.lock` | MEDIUM — same |

---

### 12. test/mix_generate_rules_test.exs — MixGenerateRulesTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-2 | build_thresholds/1 tests | unit | None | None | NONE |
| 3-6 | CursorTemplate.render/1 tests | unit | None | None | NONE |
| 7-9 | CopilotTemplate.render/1 tests | unit | None | None | NONE |
| 10-13 | mix lei.generate_rules task tests | integration | None | Filesystem (tmp dir) | NONE |

**Assessment:** Fully deterministic. Uses temp directories with `on_exit` cleanup. `async: true`. **Exemplary test design.**

---

### 13. test/mix_scan_test.exs — Mix.Tasks.ScanTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | run scan, validate report | e2e | `:long, :network` | Scans CWD's mix.lock → clones all | CRITICAL — 34 repos |
| 2 | should fail with valid message | unit | `:long` | None | NONE |
| 3 | run scan against bitbucket repo | e2e | `:long, :network` | `bitbucket.org/npa_io/ueberauth_bitbucket` | HIGH |
| 4 | run scan against multi-hub repo | e2e | `:long, :network` | `github.com/kitplummer/mix_test_project` | HIGH |
| 5-8 | fixture-based npm/yarn scans | unit | `:long` | `./test/fixtures/*` | LOW |
| 9 | run scan on JS repo | e2e | `:long, :network` | `github.com/juliangarnier/anime` | HIGH |
| 10 | return 2 reports for package-lock and yarn | unit | `:long` | `./test/fixtures/*` | LOW |
| 11 | run scan against requirements.txt | unit | `:long` | `./test/fixtures/*` | LOW |
| 12 | run scan on python repo | e2e | `:long, :network` | `github.com/kitplummer/clikan` | HIGH |

**Flakiness sources:**
- Test 1 scans ALL project dependencies (34 repos!) — extremely slow and network-heavy
- Hardcoded counts (`34 repo_count`, `14 dependency_count`) break when mix.exs changes

---

### 14. test/npm/package_json_test.exs — PackageJSONTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts deps from package.json | unit | None | `./test/fixtures/packagejson` | MEDIUM — CWD-relative |
| 2 | extracts deps from package-lock.json | unit | None | `./test/fixtures/package-lockjson` | MEDIUM — CWD-relative |

---

### 15. test/npm/yarnlock_test.exs — YarnlockTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts deps from yarn.lock | unit | None | `./test/fixtures/yarnlock` | MEDIUM — CWD-relative |

---

### 16. test/project_ident_test.exs — ProjectIdentTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | is_python?(repo) | e2e | `@moduletag :network, :long` | `bitbucket.org/kitplummer/clikan` | HIGH |
| 2 | is_node?(repo) | e2e | (module tags) | `github.com/expressjs/express` | HIGH |
| 3 | is_go_mod?(repo) | e2e | (module tags) | `github.com/go-kit/kit` | HIGH |
| 4 | is_cargo?(repo) | e2e | (module tags) | `github.com/clap-rs/clap` | HIGH — hardcoded 7 Cargo.toml paths |
| 5 | is_rubygem?(repo) | e2e | (module tags) | `github.com/rubocop-hq/rubocop` | HIGH |
| 6 | is_maven?(repo) | e2e | (module tags) | `github.com/kitplummer/snyk-maven-plugin` | HIGH — 22 pom.xml paths |
| 7 | is_gradle?(repo) | e2e | (module tags) | `github.com/ReactiveX/RxKotlin` | HIGH |
| 8 | find_files | unit | `network: false, long: false` | CWD (git repo) | LOW |
| 9 | many build or package managers | e2e | (module tags) | `github.com/xword/java-npm-gradle-integration-example` | HIGH |

**Flakiness sources:**
- 8 different remote repos cloned
- Hardcoded exact file paths within repos — any file add/remove upstream breaks tests
- `clap-rs/clap` is actively maintained with frequent workspace changes

---

### 17. test/pypi/requirements_test.exs — RequirementsTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts deps from requirements.txt | unit | None | None (inline data) | NONE |

**Assessment:** Fully deterministic. Pure parsing test with inline fixture. Exemplary.

---

### 18. test/repo_test.exs — RepoTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | repo struct encodes and decodes correctly | unit | None | None | NONE |

**Assessment:** Fully deterministic. Pure serialization test.

---

### 19. test/risk_logic_test.exs — RiskLogicTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-18 | confirm (various) risk levels | unit | None | None | NONE |
| - | doctest RiskLogic | unit | None | None | NONE |

**Assessment:** Fully deterministic. Pure logic tests. `async: true`. Exemplary.

---

### 20. test/sbom/cyclonedx_test.exs — Lei.Sbom.CycloneDXTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-5 | CycloneDX generation tests | unit | None | None (module attributes) | NONE |

**Assessment:** Fully deterministic. Uses `@single_report`/`@multi_report` module attributes. `async: true`. Exemplary.

---

### 21. test/sbom/spdx_test.exs — Lei.Sbom.SPDXTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-6 | SPDX generation tests | unit | None | None (module attributes) | NONE |

**Assessment:** Fully deterministic. `async: true`. Exemplary.

---

### 22. test/sbom_module_test.exs — Lowendinsight.SbomModuleTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | has sbom? | integration | None | CWD must be git repo with bom.xml | HIGH |
| 2 | has spdx? | integration | None | CWD must be git repo | **FAILING** |

**Current failure:** `has_spdx?` consistently fails with:
```
** (MatchError) no match of right hand side value:
    {:error, %Git.Error{message: "fatal: not a git repository...", code: 128}}
```
Both tests use `GitModule.get_repo(".")` which requires CWD to be a recognized git repository. In worktree setups, this can fail depending on git version and configuration.

---

### 23. test/time_helper_test.exs — TimeHelperTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | convert seconds to string | unit | None | None | NONE |
| 2 | get weeks from seconds | unit | None | None | NONE |
| 3 | get days from seconds | unit | None | None | NONE |
| 4 | compute delta | unit | None | System clock | LOW — bounded assertions |
| - | doctest TimeHelper | unit | None | None | NONE |

**Assessment:** Mostly deterministic. Test 4 uses time-relative assertions that shift but are bounded loosely enough.

---

### 24. test/cargo/cargofile_test.exs — CargofileTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts deps from Cargo.toml | unit | None | `./test/fixtures/cargotoml` | MEDIUM — CWD-relative |
| 2 | returns correct file_names | unit | None | None | NONE |
| 3 | handles Cargo.toml with only deps | unit | None | None (inline data) | NONE |
| 4 | handles Cargo.toml with no deps | unit | None | None (inline data) | NONE |

**Assessment:** Good mix. Tests 3-4 (inline data) are exemplary.

---

### 25. test/cargo/cargolock_test.exs — CargolockTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1 | extracts packages from Cargo.lock | unit | None | `./test/fixtures/cargolock` | MEDIUM — CWD-relative |
| 2 | returns correct file_names | unit | None | None | NONE |
| 3 | parses git sources | unit | None | `./test/fixtures/cargolock` | MEDIUM — CWD-relative |
| 4 | parses git sources from other hosts | unit | None | `./test/fixtures/cargolock` | MEDIUM — CWD-relative |
| 5 | handles packages without source | unit | None | `./test/fixtures/cargolock` | MEDIUM — CWD-relative |
| 6 | handles empty Cargo.lock | unit | None | None (inline data) | NONE |
| 7 | handles Cargo.lock with only crates.io | unit | None | None (inline data) | NONE |

**Assessment:** Good pattern. Inline tests (6-7) are exemplary.

---

### 26. test/cargo/cargo_scanner_test.exs — CargoScannerTest

| # | Test | Category | Tags | External Deps | Flakiness Risk |
|---|------|----------|------|---------------|----------------|
| 1-4 | Scanner edge case tests | unit | None | None (inline data) | NONE |

**Assessment:** Fully deterministic. Excellent test design.

---

## Flakiness Sources

### 1. Network Dependencies (CRITICAL)
**Affected tests:** 57 (all `:network`/`:long` tagged)

Remote repositories cloned during tests:

| Repository | Risk | Notes |
|------------|------|-------|
| `github.com/kitplummer/xmpp4rails` | LOW | Owner-controlled |
| `github.com/kitplummer/lita-cron` | LOW | Owner-controlled |
| `github.com/kitplummer/kit` | LOW | Owner-controlled |
| `github.com/kitplummer/libconfuse` | LOW | Owner-controlled |
| `github.com/kitplummer/clikan` | LOW | Owner-controlled |
| `github.com/kitplummer/mix_test_project` | LOW | Owner-controlled |
| `github.com/kitplummer/snyk-maven-plugin` | LOW | Owner-controlled |
| `github.com/expressjs/express` | MEDIUM | 3rd party, stable |
| `github.com/robbyrussell/oh-my-zsh` | MEDIUM | 3rd party, stable |
| `github.com/satori/go.uuid` | HIGH | Archived |
| `github.com/shadowsocks/shadowsocks` | HIGH | Censored, unpredictable |
| `github.com/hmfng/modal.git` | HIGH | Small personal repo |
| `github.com/go-kit/kit` | MEDIUM | Active, may change structure |
| `github.com/clap-rs/clap` | HIGH | Active workspace changes often |
| `github.com/rubocop-hq/rubocop` | MEDIUM | Active |
| `github.com/ReactiveX/RxKotlin` | MEDIUM | |
| `github.com/xword/java-npm-gradle-integration-example` | HIGH | Small personal repo |
| `github.com/juliangarnier/anime` | MEDIUM | |
| `github.com/amorphid/artifactory-elixir` | HIGH | Small personal repo |
| `github.com/wli0503/Mixeur` | HIGH | Small personal repo |
| `github.com/betesy/201601betesy_test.git` | HIGH | Small personal repo |
| `bitbucket.org/kitplummer/clikan` | MEDIUM | Bitbucket |
| `bitbucket.org/npa_io/ueberauth_bitbucket` | HIGH | 3rd party Bitbucket |
| `gitlab.com/kitplummer/infrastructure` | MEDIUM | GitLab |
| `gitlab.com/lowendinsight/test/pymodule` | LOW | Owner-controlled |

### 2. Hardcoded Expected Values (HIGH)
Tests assert exact values from live repos:
- Commit counts, contributor counts, contribution maps
- Exact file paths within cloned repos
- Exact timestamps and hash values
- Total file counts and binary file names

Any upstream change (new commit, renamed file, new contributor) breaks these tests.

### 3. CWD-Relative Paths (MEDIUM)
Tests use `./test/fixtures/...` and `./mix.lock` paths:
- EncoderTest — 4 tests
- LockfileTest — 1 test
- MixfileTest — 1 test
- PackageJSONTest — 2 tests
- YarnlockTest — 1 test
- DependenciesTest — 2 tests
- CargofileTest — 1 test
- CargolockTest — 4 tests

These fail if tests are run from a different working directory.

### 4. Git Worktree Sensitivity (HIGH)
- `SbomModuleTest` — `GitModule.get_repo(".")` fails in git worktree setups
- `AnalyzerTest.analyze local path repo` — uses `File.cwd()` as git repo
- `GitModuleTest.get local path repo` — uses `"."` as git repo

### 5. Self-Referential Tests (MEDIUM)
Tests that read the project's own files:
- `EncoderTest.get mix.lock dependency tree as json` — reads `./mix.lock`, asserts `"bunt"` first
- `DependenciesTest` — reads `./mix.lock` via Mix task
- `ScanTest.run scan, validate report` — scans all 34 project deps

These break when project dependencies change.

### 6. Time-Dependent Assertions (LOW)
- `TimeHelperTest.compute delta` — uses `> 550` weeks from 2009, `>= 30` from 2019
- `AnalyzerTest.get report` — uses `context[:weeks]` computed from live commit date
- `GitModuleTest.convert to delta` — uses `553 <= weeks`

---

## Determinism Recommendations

### Priority 1: Fix the Consistent Failure
**SbomModuleTest** — `has_sbom?` and `has_spdx?` use `GitModule.get_repo(".")` which fails in git worktrees. Fix by either:
- Using `__DIR__` to navigate to a known git repo path
- Creating a fixture repo via `FixtureHelper`
- Using Mox to mock `GitModule` (the mock is already defined but unused)

### Priority 2: Use the Existing Fixture Infrastructure
`FixtureHelper` and `GitModule.Mock` are already defined but **no test uses them**. Migrate tests to use:
- `FixtureHelper.ensure_fixtures_exist()` + `FixtureHelper.fixture_path(:simple_repo)` for git-dependent tests
- `GitModule.Mock` via Mox for unit tests that call `GitModule` functions

### Priority 3: Replace CWD-Relative Paths
Replace all `./test/fixtures/...` with `Path.join(__DIR__, "fixtures/...")` or similar absolute path construction. This makes tests runnable from any CWD.

### Priority 4: Replace Self-Referential Tests
Tests reading `./mix.lock` should use fixture files instead. The `EncoderTest.get mix.lock dependency tree as json` test and `DependenciesTest` tests should use `test/fixtures/lockfile` rather than the project's own lock file.

### Priority 5: Separate Network Tests into Integration Suite
The test_helper.exs exclusion system is good but could be improved:
- Add a `mix test.integration` alias that includes `:network` and `:long`
- Keep `mix test` as the fast, deterministic unit suite
- Document test modes clearly in CI configuration

### Priority 6: Replace Hardcoded Upstream Values
For network tests that must remain, replace exact assertions with structural assertions:
- Instead of `assert 7 == commit_count`, use `assert commit_count > 0`
- Instead of exact contributor lists, verify structure: `assert is_list(contributors)`
- Use `assert Map.has_key?(result, :risk)` instead of `assert "critical" == result[:risk]`

### Priority 7: Add Deterministic Alternatives
For each network test, consider whether a deterministic equivalent can be added using:
- Fixture repos (from `setup_fixtures.sh`)
- Mox mocks (already configured)
- Inline test data (as CycloneDX/SPDX tests demonstrate)

---

## Test Categorization Summary

| Category | Count | Deterministic? |
|----------|-------|----------------|
| Unit (no external deps) | 46 | Yes |
| Unit (CWD-relative fixtures) | 12 | Mostly (CWD-dependent) |
| Unit (self-referential) | 3 | Fragile (mix.lock changes) |
| Integration (local git) | 3 | Fragile (worktree issues) |
| Integration (network) | 33 | No |
| E2E (network + hardcoded) | 13 | No |
| **Total** | **110** | **46 fully deterministic** |

---

## Exemplary Test Patterns (to replicate)

These test files demonstrate the right approach to deterministic testing:

1. **RiskLogicTest** — Pure logic, `async: true`, zero deps
2. **CycloneDXTest / SPDXTest** — Module attributes as fixtures, `async: true`
3. **MixGenerateRulesTest** — Temp dirs with `on_exit` cleanup, inline data for templates
4. **CargoScannerTest** — Inline struct data, edge case coverage
5. **GitHelperTest** — `setup_all` with inline string fixtures
6. **RequirementsTest** — Inline multiline string as test input
