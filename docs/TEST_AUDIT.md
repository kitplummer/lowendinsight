# LEI Test Suite Audit

**Audit Date:** 2026-02-05
**Framework:** ExUnit (Elixir)
**Total Test Files:** 20
**Test Helper:** `test/test_helper.exs`

---

## Executive Summary

The LEI test suite contains **85+ tests** across 20 test files. The majority of tests are **integration tests** that rely on **external network access** to clone Git repositories from GitHub, GitLab, and Bitbucket. This creates significant **flakiness risks** due to:

1. Network dependency for most tests
2. External repository state changes over time
3. Hardcoded expected values tied to specific repository states
4. Long execution times for clone operations

---

## Test File Audit

### 1. `test/analyzer_test.exs`

**Module:** `AnalyzerTest`
**Category:** Integration
**Async:** `false`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `setup_all` | Clones xmpp4rails repo to get commit date | Network, GitHub | Clone failures, rate limiting |
| `analyze local path repo` | Analyzes current working directory | Filesystem | None |
| `get empty report` | Tests empty report generation | None | None |
| `get report` | Full analysis of xmpp4rails | Network, GitHub | Repository state changes, hardcoded contributor data |
| `get multi report mixed risks` | Analyzes xmpp4rails + oh-my-zsh | Network, GitHub | Large repo (oh-my-zsh), rate limiting |
| `get multi report for dot named repo` | Tests URL-encoded repo with dot | Network, GitHub | Repository availability |
| `get multi report mixed risks and bad repo` | Tests with non-existent repo | Network, GitHub | None (expected failure) |
| `analyze a repo with a single commit` | Tests shadowsocks/shadowsocks | Network, GitHub | Repository state/availability |
| `analyze a repo with a dot in the url` | Tests satori/go.uuid | Network, GitHub | Repository availability |
| `input of optional start time` | Tests start time parameter | Network, GitHub | Repository availability |
| `get report fail` | Tests non-existent repo handling | Network, GitHub | None (expected failure) |
| `get report when subdirectory and valid` | Tests GitLab subgroup | Network, GitLab | GitLab availability |
| `get report fail when subdirectory and not valid` | Tests invalid subdirectory | Network, GitHub | None (expected failure) |
| `get single repo report validated by report schema` | Schema validation | Network, GitHub | Schema changes |
| `get multi repo report validated by report schema` | Multi-repo schema validation | Network, GitHub | Schema changes |

**Tags:** `@tag :long`, `@tag timeout: 180_000`

---

### 2. `test/files_test.exs`

**Module:** `FilesTest`
**Category:** Integration
**Async:** `false`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `analyze files in path repo` | Analyzes xmpp4rails file structure | Network, GitHub | Repository file changes, hardcoded counts |
| `analyze files in elixir repo` | Analyzes gtri/lowendinsight files | Network, GitHub | Repository file changes, hardcoded counts (178 files, 1 binary) |

**Risk:** Hardcoded file counts (`total_file_count: 15`, `total_file_count: 178`) will break if repositories change.

---

### 3. `test/git_helper_test.exs`

**Module:** `GitHelperTest`
**Category:** Unit
**Async:** implicit (default true)

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `correct implementation` | Parse valid contributor header | None | None |
| `incorrect email` | Parse malformed email | None | None |
| `semicolon error` | Handle semicolon in email | None | None |
| `number error` | Handle numeric name | None | None |
| `empty name error` | Handle missing name | None | None |
| `name with opening angle bracket` | Parse malformed name | None | None |
| `email with closing angle bracket` | Parse malformed email | None | None |

**Tags:** `@tag :helper` (all tests)
**Note:** These are proper unit tests with no external dependencies - good pattern.

---

### 4. `test/git_module_test.exs`

**Module:** `GitModuleTest`
**Category:** Integration
**Async:** implicit (default true)

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `setup_all` | Clones 6 repositories | Network (GitHub, Bitbucket, GitLab) | Multiple clone operations, rate limiting |
| `get current hash` | Get commit hash | Cloned repo | Hash changes if repo rebased |
| `get default branch` | Get default branch name | Cloned repo | Branch renames |
| `get commit count for default branch` | Count commits | Cloned repo | Hardcoded count (7) |
| `get commit count for default branch for path` | Count local commits | Local filesystem | None |
| `get contributor list 1` | Count contributors | Cloned repo | Hardcoded count (1) |
| `get contributor list 3` | Clone + count contributors | Network, GitHub | Additional clone, hardcoded count (4) |
| `get contribution maps` | Get contributor details | Cloned repo | Hardcoded contributor data |
| `get cleaned contribution map` | Get cleaned contributor data | Cloned repo | Hardcoded contributor data |
| `get commit dates` | Get timestamp list | Cloned repo | Hardcoded timestamps |
| `get last commit date` | Get latest commit date | Cloned repo | Hardcoded date |
| `get last contribution by contributor date` | Get contributor's last date | Cloned repo | Hardcoded date |
| `convert to delta` | Calculate week delta | Cloned repo | Time-dependent assertion |
| `get commit and tag dates` | Get tag timing data | Cloned repo | Hardcoded timing values |
| `get code changes in last 2 commits` | Diff analysis | Multiple cloned repos | Hardcoded diff counts |
| `get contributor counts` | Distribution analysis | Multiple cloned repos | Hardcoded distribution values |
| `get the number of contributors over a certain percentage` | Functional contributors | Multiple cloned repos | Hardcoded counts |
| `get local path repo` | Get local repo | Filesystem | None |
| `error on not a valid local path repo` | Error handling | Filesystem | None |
| `get repo size` | Get size | Cloned repo | None (non-empty assertion) |
| `subgroup repo from gitlab` | GitLab subgroup test | Cloned repo | None (non-empty assertion) |
| `repo with a no name committer` | Parse unusual shortlog | None | None |

**Critical Risk:** `setup_all` clones 6 repositories which is expensive and failure-prone.

---

### 5. `test/helpers_test.exs`

**Module:** `Lowendinsight.HelpersTest`
**Category:** Unit
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `converter works?` | Config to JSON conversion | None | None |
| `validate path url` | Validate file:// URLs | Filesystem | None |
| `validate urls` | Validate URL list | None | None |
| `validate scheme` | Reject invalid schemes | None | None |
| `removes git+ only when it is a prefix in url` | URL prefix handling | None | None |

**Status:** Clean unit tests - no external dependencies.

---

### 6. `test/hex/encoder_test.exs`

**Module:** `Lowendinsight.Hex.EncoderTest`
**Category:** Unit
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `encoder works for mix.exs` | Parse mix.exs fixture | Local fixture file | None |
| `encoder works for mix.lock` | Parse mix.lock fixture | Local fixture file | None |
| `get dependency tree as json` | Lockfile to JSON | Local fixture file | None |
| `get mix.lock dependency tree as json` | Real mix.lock parsing | Local filesystem (mix.lock) | Project dependency changes |

**Status:** Mostly fixture-based - good pattern except last test uses live `mix.lock`.

---

### 7. `test/hex/lockfile_test.exs`

**Module:** `LockfileTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `extracts dependencies from mix.lock` | Parse lockfile fixture | Local fixture file | None |

**Status:** Clean unit test using fixture.

---

### 8. `test/hex/mixfile_test.exs`

**Module:** `MixfileTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `extracts dependencies from mix.exs` | Parse mixfile fixture | Local fixture file | None |

**Status:** Clean unit test using fixture.

---

### 9. `test/mix_analyze_test.exs`

**Module:** `Mix.Tasks.AnalyzeTest`
**Category:** Integration/E2E
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `run analysis, validate report, return report` | Full E2E test with 6 repos | Network (GitHub, GitLab) | 6 clone operations, rate limiting, long execution |

**Tags:** `@tag :long`
**Risk:** Single test analyzes 6 different repositories sequentially - extremely slow and flaky.

**Repos tested:**
- expressjs/express
- kitplummer/blah (error case)
- amorphid/artifactory-elixir
- wli0503/Mixeur
- betesy/201601betesy_test.git
- gitlab.com/lowendinsight/test/pymodule

---

### 10. `test/mix_bulk_analyze_test.exs`

**Module:** `Mix.Tasks.BulkAnalyzeTest`
**Category:** Integration
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `run scan, validate report, return report` | Bulk analyze from file | Network, GitHub | Multiple clones |
| `run scan against NPM cleaned list` | Analyze NPM packages | Network, GitHub | 10 repos, rate limiting |
| `run scan against non-existent file` | Error handling | Filesystem | None |
| `run scan against invalid file` | Error handling | Filesystem | None |

**Tags:** `@tag :long`, `@tag timeout: 200_000`

---

### 11. `test/mix_dependencies_test.exs`

**Module:** `Mix.Tasks.DependenciesTest`
**Category:** Unit/Integration
**Async:** `false`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `should fail with valid message` | Invalid path handling | Filesystem | None |
| `run scan and report against no args local` | Local dependency scan | Local filesystem | Project dependency changes |
| `run scan and report against given local` | Local dependency scan | Local filesystem | Project dependency changes |

**Status:** Relatively safe - uses local filesystem.

---

### 12. `test/mix_scan_test.exs`

**Module:** `Mix.Tasks.ScanTest`
**Category:** Integration
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `run scan, validate report, return report` | Full local scan | Network (analyzes deps) | Hardcoded counts (34 repos, 14 deps) |
| `should fail with valid message` | Invalid path handling | Filesystem | None |
| `run scan and report against Bitbucket package` | Clone + scan | Network, Bitbucket | Bitbucket availability, hardcoded count (16) |
| `run scan against mix_test_project` | Clone + scan | Network, GitHub | Hardcoded counts |
| `run scan against package-lock.json` | NPM scan fixture | Local fixture | None |
| `run scan against first-degree dependencies` | NPM scan fixture | Local fixture | None |
| `run scan against package.json and yarn.lock` | Yarn scan fixture | Local fixture | None |
| `run scan against package.json, package-lock.json and yarn.lock` | Combined scan | Local fixture | None |
| `run scan against requirements.txt` | Python scan fixture | Local fixture | None |
| `run scan on JS repo, validate report` | Clone + scan anime repo | Network, GitHub | Clone operation |
| `return 2 reports for package-lock.json and yarn.lock` | Combined report | Local fixture | None |
| `run scan on python repo, validate report` | Clone + scan clikan | Network, GitHub | Clone operation |

**Tags:** `@tag :long`, `@tag timeout: 130_000`, `@moduletag timeout: 200000`

---

### 13. `test/npm/package_json_test.exs`

**Module:** `PackageJSONTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `extracts dependencies from package.json` | Parse package.json fixture | Local fixture | None |
| `extracts dependencies from package-lock.json` | Parse package-lock.json fixture | Local fixture | None |

**Status:** Clean unit tests using fixtures.

---

### 14. `test/npm/yarnlock_test.exs`

**Module:** `YarnlockTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `extracts dependencies from yarn.lock` | Parse yarn.lock fixture | Local fixture | None |

**Status:** Clean unit test using fixture.

---

### 15. `test/project_ident_test.exs`

**Module:** `ProjectIdentTest`
**Category:** Integration
**Async:** `false`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `setup_all` | Initializes project types | None | None |
| `is_python?(repo)` | Clone + identify Python | Network, Bitbucket | Clone operation |
| `is_node?(repo)` | Clone + identify Node | Network, GitHub | Clone operation |
| `is_go_mod?(repo)` | Clone + identify Go | Network, GitHub | Clone operation |
| `is_cargo?(repo)` | Clone + identify Rust | Network, GitHub | Hardcoded Cargo.toml paths |
| `is_rubygem?(repo)` | Clone + identify Ruby | Network, GitHub | Clone operation |
| `is_maven?(repo)` | Clone + identify Maven | Network, GitHub | Hardcoded pom.xml paths |
| `is_gradle?(repo)` | Clone + identify Gradle | Network, GitHub | Clone operation |
| `find_files` | Local file finding | Local filesystem | None |
| `many build or package managers` | Clone + multi-type | Network, GitHub | Hardcoded path lists |

**Tags:** `@moduletag timeout: 100000`
**Risk:** Each test clones a different repository, then deletes it. Very slow and network-dependent.

---

### 16. `test/pypi/requirements_test.exs`

**Module:** `RequirementsTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `extracts dependencies from requirements.txt` | Parse requirements | In-memory string | None |

**Status:** Clean unit test with inline data.

---

### 17. `test/repo_test.exs`

**Module:** `RepoTest`
**Category:** Unit
**Async:** implicit

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `repo struct encodes and decodes correctly` | JSON serialization | None | None |

**Status:** Clean unit test.

---

### 18. `test/risk_logic_test.exs`

**Module:** `RiskLogicTest`
**Category:** Unit
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `confirm sbom risk medium` | Test risk level | None | None |
| `confirm contributor critical` | Test threshold | None | None |
| `confirm contributor high` | Test threshold | None | None |
| `confirm contributor medium` | Test threshold | None | None |
| `confirm contributor low` | Test threshold | None | None |
| `confirm currency critical` | Test threshold | None | None |
| `confirm currency more than critical` | Test threshold | None | None |
| `confirm currency high` | Test threshold | None | None |
| `confirm currency more than high` | Test threshold | None | None |
| `confirm currency medium` | Test threshold | None | None |
| `confirm currency more than medium` | Test threshold | None | None |
| `confirm currency low` | Test threshold | None | None |
| `confirm large commit low` | Test threshold | None | None |
| `confirm large commit medium` | Test threshold | None | None |
| `confirm large commit high` | Test threshold | None | None |
| `confirm large commit critical` | Test threshold | None | None |
| `confirm functional commiters low` | Test threshold | None | None |
| `confirm functional commiters medium` | Test threshold | None | None |
| `confirm functional commiters high` | Test threshold | None | None |
| `confirm functional commiters critical` | Test threshold | None | None |

**Status:** Excellent unit tests - deterministic, fast, no dependencies.

---

### 19. `test/sbom_module_test.exs`

**Module:** `Lowendinsight.SbomModuleTest`
**Category:** Unit
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `has sbom?` | Check SBOM in local repo | Local filesystem | Repo state changes |
| `has spdx?` | Check SPDX in local repo | Local filesystem | Repo state changes |

**Status:** Uses local repository - relatively stable.

---

### 20. `test/time_helper_test.exs`

**Module:** `TimeHelperTest`
**Category:** Unit
**Async:** `true`

| Test Name | Description | External Dependencies | Flakiness Sources |
|-----------|-------------|----------------------|-------------------|
| `convert seconds to string` | Time formatting | None | None |
| `get weeks from seconds` | Time calculation | None | None |
| `get days from seconds` | Time calculation | None | None |
| `compute delta` | Time delta from date | System clock | Time-dependent assertions |

**Note:** Last test uses `assert weeks > 550` which will continue to pass as time moves forward, but the actual value changes.

---

## Summary Statistics

### Test Categories

| Category | Count | Files |
|----------|-------|-------|
| **Unit** | ~40 | git_helper, helpers, hex/encoder, hex/lockfile, hex/mixfile, npm/package_json, npm/yarnlock, pypi/requirements, repo, risk_logic, sbom_module, time_helper |
| **Integration** | ~40 | analyzer, files, git_module, mix_analyze, mix_bulk_analyze, mix_dependencies, mix_scan, project_ident |
| **E2E** | ~5 | mix_analyze (full pipeline tests) |

### External Dependencies

| Dependency | Test Files Affected | Impact |
|------------|--------------------|---------|
| **GitHub API/Git Clone** | 10 | High - rate limiting, network failures |
| **GitLab API/Git Clone** | 3 | Medium - availability |
| **Bitbucket API/Git Clone** | 3 | Medium - availability |
| **Local Filesystem** | 15 | Low - stable |
| **System Clock** | 2 | Low - time-dependent assertions |

### Flakiness Risk Matrix

| Risk Level | Count | Primary Causes |
|------------|-------|----------------|
| **Critical** | 15 | Network-dependent clones, hardcoded repo state |
| **High** | 10 | Multiple clone operations, rate limiting |
| **Medium** | 8 | Hardcoded counts, time-sensitive assertions |
| **Low** | ~50 | Fixture-based, pure logic tests |

---

## Recommendations for Determinism

### 1. Mock Git Operations for Unit Tests

**Problem:** Integration tests clone real repositories, making them slow and flaky.

**Solution:**
```elixir
# Create a mock GitModule for unit tests
defmodule GitModule.Mock do
  def clone_repo(_url, _path), do: {:ok, %{path: "/tmp/mock"}}
  def get_contributor_count(_repo), do: {:ok, 5}
  # ... etc
end
```

### 2. Use Fixtures for Repository State

**Problem:** Tests depend on external repo state that changes over time.

**Solution:**
- Create tarball fixtures of test repositories at known states
- Extract and use these for consistent testing
- Example: `test/fixtures/repos/xmpp4rails.tar.gz`

### 3. Separate Test Suites

**Current:** All tests run together with `mix test`

**Recommended:**
```bash
# Fast unit tests (default CI)
mix test --exclude long --exclude integration

# Full integration tests (nightly/manual)
mix test --only integration

# Long-running tests (weekly)
mix test --only long
```

### 4. Add Retry Logic for Network Tests

**Problem:** Transient network failures cause test failures.

**Solution:**
```elixir
# In test_helper.exs
ExUnit.configure(exclude: [:long], retry: 2)
```

### 5. Replace Hardcoded Values with Dynamic Assertions

**Problem:** Assertions like `assert 7 == total_commits` break when repos change.

**Solution:**
```elixir
# Instead of:
assert 7 == repo_data[:data][:git][:total_commits_on_default_branch]

# Use:
assert is_integer(repo_data[:data][:git][:total_commits_on_default_branch])
assert repo_data[:data][:git][:total_commits_on_default_branch] > 0
```

### 6. Use VCR/Cassette Pattern for HTTP Requests

**Problem:** Tests make real HTTP requests that can fail or return different data.

**Solution:** Use a library like `ExVCR` to record and replay HTTP interactions:
```elixir
use_cassette "github_xmpp4rails" do
  {:ok, report} = AnalyzerModule.analyze(["https://github.com/kitplummer/xmpp4rails"], "test")
end
```

### 7. Time-Independent Assertions

**Problem:** Tests like `assert weeks >= 30` or `assert weeks > 550` are time-dependent.

**Solution:**
```elixir
# Instead of checking absolute values, check calculations are correct
date = "2019-01-07T03:23:20Z"
seconds = TimeHelper.get_commit_delta(date)
# Calculate expected value based on current time
expected_weeks = div(DateTime.diff(DateTime.utc_now(), ~U[2019-01-07 03:23:20Z]), 604800)
assert_in_delta TimeHelper.sec_to_weeks(seconds), expected_weeks, 1
```

### 8. Add Test Tags Consistently

**Current:** Inconsistent use of `:long` tag.

**Recommended Tags:**
```elixir
@tag :unit          # Fast, no external deps
@tag :integration   # Requires network/filesystem
@tag :long          # Takes > 30 seconds
@tag :network       # Requires network access
@tag :git           # Clones repositories
```

---

## Priority Actions

1. **Immediate:** Tag all network-dependent tests with `@tag :network` and exclude from default CI
2. **Short-term:** Create fixture tarballs for the 5 most-used test repositories
3. **Medium-term:** Implement mock modules for GitModule operations
4. **Long-term:** Adopt VCR pattern for all external HTTP/Git operations

---

## Test File Quick Reference

| File | Unit Tests | Integration | Network Deps | Fixtures Used |
|------|------------|-------------|--------------|---------------|
| analyzer_test.exs | 2 | 13 | Yes | No |
| files_test.exs | 0 | 2 | Yes | No |
| git_helper_test.exs | 7 | 0 | No | No |
| git_module_test.exs | 2 | 21 | Yes | No |
| helpers_test.exs | 5 | 0 | No | No |
| hex/encoder_test.exs | 4 | 0 | No | Yes |
| hex/lockfile_test.exs | 1 | 0 | No | Yes |
| hex/mixfile_test.exs | 1 | 0 | No | Yes |
| mix_analyze_test.exs | 0 | 1 | Yes | No |
| mix_bulk_analyze_test.exs | 2 | 2 | Yes | Yes |
| mix_dependencies_test.exs | 3 | 0 | No | No |
| mix_scan_test.exs | 6 | 6 | Yes | Yes |
| npm/package_json_test.exs | 2 | 0 | No | Yes |
| npm/yarnlock_test.exs | 1 | 0 | No | Yes |
| project_ident_test.exs | 1 | 9 | Yes | No |
| pypi/requirements_test.exs | 1 | 0 | No | No |
| repo_test.exs | 1 | 0 | No | No |
| risk_logic_test.exs | 20 | 0 | No | No |
| sbom_module_test.exs | 2 | 0 | No | No |
| time_helper_test.exs | 4 | 0 | No | No |
