# Changelog

Notable changes to the `lowendinsight` library and the hosted service in this
repository. The library is published to Hex; the service is deployed from the
same tree (ADR-003).

## 0.12.0 — unreleased

### New

- **Go, Composer and RubyGems resolve.** `Lei.PackageRepository` understood npm,
  hex, pypi and cargo, which is why a customer scanning a Go service got nothing
  from us. Go needs no request at all — a module path is its location, and
  `normalize/1` already trims a `/v2` major version, a `/service/s3` submodule
  path and anything on a host we cannot clone. Composer reads
  `repo.packagist.org`'s declared `source.url`; RubyGems reads
  `source_code_uri`, which commonly points at a tag
  (`.../rails/tree/v8.1.4`) and is trimmed to the repository.

  A vanity Go path — `k8s.io/client-go`, `golang.org/x/net` — is still refused
  rather than guessed. Go's own `?go-get=1` mechanism resolves those, and it was
  tested: `golang.org/x/net` gives `go.googlesource.com/net` and
  `gopkg.in/yaml.v3` gives itself, both on hosts this will not clone. Following
  the protocol would cost a request per module and end in the same answer.

- **`Lei.PackageRepository.ecosystems/0`**, so a caller can ask what resolves
  rather than keeping a list. `LeiService.CacheBaseline` kept its own copy of
  four, so adding a resolver here would otherwise leave every caller of that
  still refusing the ecosystem — two lists of one fact, and the copy decided
  what got measured.

## 0.11.0 — 2026-10-03

Sixteen commits since 0.10.0 were never released, and the gap was found by
depending on the published package from outside this tree: a survey built on
`lowendinsight 0.10.0` could not see `functional_commit_currency_weeks` at all,
because the module that computes it is in this list.

### New

- **`Lei.CommitSubstance`: commit currency measured from the last commit that
  meant something.** Plain currency is reset by anything — a README typo, a
  licence year bump, a merged Dependabot PR — so a repository with no human
  involvement for a year could report `low` on automation alone, at any
  threshold. A commit is not substantive when its author classifies as a bot or
  every path it touches is documentation or repository metadata. AI
  co-authorship does *not* make a commit non-substantive: an agent-assisted
  commit still represents a person deciding the project needed changing, and
  `agentic_classification` is the metric that speaks to that.
  `functional_commit_currency_weeks` and `functional_commit_currency_risk` are
  new result fields, with their own thresholds rather than sharing the plain
  ones.
- **`Lei.ReportFreshness`: currency recomputed on the way out of the cache.**
  Five of the six risk metrics are pure functions of a cloned history and stay
  correct while the repository does not move. Commit currency is derived from
  `DateTime.utc_now()`, so a stored week count reported the risk a repository
  held when it was analysed — a project drifting into abandonment kept its old
  verdict, which made the cache a way of suppressing the one signal the analysis
  exists to raise. Recomputed from the stored `last_commit_date`: no clone, no
  network.
- **`Lei.RiskProfile`: the distribution a verdict was collapsed from.**
  `data.risk` is the worst of a repository's metrics, which made "one functional
  contributor, active this month" and "one functional contributor, silent two
  years" read identically. The verdict is unchanged and the counts are reported
  beside it — no weights, no 0-100 score.
- **Manifest ranking, and directness rather than centrality.** A report is
  rankable, the dependency edges already being received are kept rather than
  discarded, and one registry fetch answers both the repository and the
  dependency questions.

### Fixed

- **An npm `repository` published as a string raised** `FunctionClauseError`
  inside a `Task`, taking a whole batch job down rather than failing one
  package. `@nodelib/fs.stat` publishes that form and is a transitive dependency
  of most npm projects, so any batch analysis over a real npm manifest ended on
  it. The shorthand forms (`github:o/r`, a bare `o/r`, `git@host:o/r`) and URLs
  pointing into a monorepo directory now resolve too; each previously read as
  "this package has no repository".
- **Resolution asks for one version, not every version ever published.** npm's
  package document for `typescript` is 15.7 MB against 4.8 KB for
  `/typescript/latest` — the same `repository` field. The download was never the
  cost; decoding 15.7 MB to read one string was, at 19.8 s per package.
  `describe/3` and `dependencies/3` still take the full document, because
  `dist-tags` and `versions` exist only there.
- **Analyses that determined nothing are no longer cached**, and arguments are
  validated before work starts.

### Changed

- **git is run directly**, dropping a dependency unmaintained since 2018.
- README and LICENCE ship in the package.

## 0.10.0 — 2026-09-16

### Breaking, for library users

- **Elixir 1.17 or newer is required.** httpoison 3 requires it, and the
  toolchain moved to Elixir 1.20.4 / OTP 28.5.
- **httpoison 3 / hackney 4.** hackney 1.25 carried four advisories, the
  highest a SOCKS5 TLS upgrade that ignored the caller's timeout
  (GHSA-gp9c-pm5m-5cxr). The fix is hackney 4, which needs httpoison 3.
- **`httpoison_retry` is gone**, replaced by `Lei.HTTP.Retry`. The policy is
  the same — retry transport timeouts, closed connections, `nxdomain` and
  HTTP 500; 5 attempts 15s apart by default — and it also retries hackney 4's
  `:connect_timeout`. Callers pass `Lei.HTTP.Retry.request(fn -> ... end)`
  instead of piping through `autoretry/2`.
- **`Lei.BatchAnalyzer.analyze/2` takes a `:schedule` function.** The library
  has no job queue; the caller supplies one, and it returns `{:ok, job_id}` or
  `{:error, reason}` per dependency. **Without it a cache miss is reported
  `"uncached"`**, where it used to be reported `"pending"` with a generated id
  that named no work.
- **`cache_mode: "fresh"` now bypasses the cache**, for the results and for
  `cache_split/2`. It was accepted and ignored, so a caller asking for a fresh
  analysis was served the cached report.
- **`jason` is a declared dependency.** The library called it in three modules
  without declaring it; inside this umbrella the service's copy hid that.

### Fixed

- **npm lookups use `registry.npmjs.org`.** `replicate.npmjs.com` answers 404
  for every package, so npm scans never found a repository and analysed the
  bare package name instead. The scan tests passed throughout: they count
  reports, and the fallback still produced one.
- **yarn.lock: scoped packages keep their names.** `@babel/core` was split at
  its first `@` and came out as `""`.
- **yarn.lock: versions compare as versions.** `Float.parse` made 1.10.0 lose
  to 1.9.0.
- **yarn 2+ (berry) lockfiles parse**, via yarn_parser 0.4; workspace entries
  are not counted as dependencies.
- **EEx comments** use `<%!-- --%>`, deprecated syntax removed for Elixir 1.20.

### Added

- **`Lei.PackageRepository`** resolves a package coordinate (npm, hex, pypi,
  cargo) to a repository URL, normalising `git+ssh`, `git://` and `.git`
  forms, and refusing an ecosystem it does not know rather than guessing.

### Security (hosted service)

From the 2026-09-14 review and its follow-ups:

- Analysis reports no longer publish the application environment; the canary
  scans every public body for secret-shaped content.
- Analyses are limited to public https URLs.
- Org key routes check the caller owns the org; sessions are bound to a live
  key; dashboard templates escape output.
- Admission checks and charges under a lock on the org, so simultaneous
  requests cannot all pass one org's allowance.
- Pro activation requires a Checkout Session confirmed with Stripe; agent
  checkout sells credits rather than a tier.
- Stripe webhooks are applied once, only when recent, and only when paid.
- A job's id is the credential for it, and polling cannot loop analysis.
- Only an operator can force a trending refresh.
- **Operator tokens must carry `exp`**, in the future and no more than 24
  hours out. Both paths verified the signature alone, so an expired token was
  accepted and one minted without `exp` never expired.
- **Signup, login and recovery are rate limited per IP** (5, 10 and 5 per
  hour). Recovery answers with a new admin API key, so unlimited guessing was
  an organisation takeover.

### Background work (ADR-004, hosted service)

Deferred work ran four ways and only one survived a restart; 79 analyses sat
`executing` for days while every check stayed green.

- Oban 2.24 on schema 14, with Lifeline rescuing orphaned jobs and Pruner
  bounding the table.
- Queue health on `/readyz` and `/metrics`; the monitor fails on stuck or
  backed-up work.
- Every job bounded by a timeout; deploys drain for 60s instead of being
  killed after 5.
- Batch misses enqueue real jobs and return their ids.
- No billing write is fire-and-forget; a cached report's refresh is queued.
- Trending is one job per language on its own queue, and cache cleaning is a
  job; Quantum is removed.

### Infrastructure

- **ADR-003:** the library is the analyzer only. The hosted service moved to
  `apps/lei_service`, with the service's settings under `:lei_service`.
  `scripts/library-isolation.sh` builds a project that depends only on the
  library and proves it compiles, boots with no configuration, analyses a
  repository, and declares no service dependency.
- **Dependency advisories** are checked with `mix hex.audit` and mix_audit
  against `scripts/acknowledged-advisories.txt`; mix_audit 0.1 had reported
  nothing while the lock held HIGH advisories.
- **Toolchain pins** (CI, every Dockerfile, `.tool-versions`) must agree;
  `scripts/check-toolchain.sh` fails when they do not. Production had been
  building on Elixir 1.15.7 with an end-of-life Alpine while CI tested 1.16.3.

## 0.9.2 — 2026-09-15

- Security release for the 0.9 line; see GHSA-mqqj-2vjh-xw24.

## 0.9.1 — 2026-03-07

- Maintenance and documentation cleanup.
- Standardized project references to GitHub.

## 0.9.0 — 2026-02-05

- **SARIF output** for the GitHub Security tab (`mix lei.sarif`).
- **ZarfGate**: quality gate for CI/CD pipelines with configurable thresholds.
- **AI rules generation** for Cursor and GitHub Copilot.
- **Files analysis**: binary file detection, README/LICENSE/CONTRIBUTING presence.
- **SPDX parser**: full SPDX SBOM parsing.
