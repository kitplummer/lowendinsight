# Changelog

Notable changes to the `lowendinsight` library and the hosted service in this
repository. The library is published to Hex; the service is deployed from the
same tree (ADR-003).

## 0.15.0 — 2026-10-05

### Changed

- **Clones are full again; `--filter=blob:none` is reverted.** It was added in
  0.14.0 to get large repositories under the service's size guard. The guard
  existed because analysis was slow, and that was a quadratic in
  `filter_contributors/1` — two full list traversals per unique contributor,
  recursing on the remainder, with `String.downcase` on both sides of every
  comparison.

  With that fixed, blobless buys nothing. Measured on the worst repository
  found:

  ```
  DefinitelyTyped, full clone   15,537 ms   peak 647 MB
  DefinitelyTyped, blobless     15,827 ms   peak 585 MB
  ```

  The full clone is marginally **faster**, and blobless was never free:
  `git log --numstat` fetched blobs over the network *during* analysis, costing
  93 ms against 3,924 ms on a 287 KB repository, and timing out two analyses in
  a study run that had succeeded before it. An airgapped deployment had no
  upstream to fetch from at all.

  `LEI_GIT_CLONE_FILTER` is gone with it.

- **The service's repository size limit is derived from disk rather than
  chosen.** `250_000` KB dated from before the quadratic was found, when large
  repositories were genuinely expensive to analyse. What the guard actually
  bounds is concurrent clone space on a root filesystem with no volume and no
  quota, and that can be computed:

  ```
  free disk              7,300,000 KB   df on the machine
  concurrency                      5    OBAN_ANALYSIS_CONCURRENCY
  margin                         60%    room for the image and logs
  per-slot allowance       876,000 KB
  GitHub size understates      x1.73    worst of three measured
  limit                    506,358 KB  ->  500_000
  ```

  This admits pandas (416 MB), jest (324 MB) and django (283 MB). It does not
  admit DefinitelyTyped, React or TypeScript, and no safe limit can: five
  concurrent DefinitelyTyped clones is 95.9% of free disk. Bounding that needs
  the concurrent disk limited directly, which is recorded in `Lei.RepoSize`
  rather than attempted.

  `LEI_MAX_REPO_SIZE_KB` still overrides it.

### Fixed

- **Contributor deduplication is linear.** `parse_shortlog/1` went from
  3,366 ms to 52 ms on React's 2,042 contributors; DefinitelyTyped's 19,983
  from not finishing in minutes to 410 ms. A full analysis of DefinitelyTyped
  went from **37.5 minutes to 15.8 seconds**, with the same verdict, the same
  peak memory and the same contributor counts — verified against git's own
  mailmap-applied figures.

## 0.14.0 — 2026-10-05

### Changed

- **Clones are blobless.** `Lei.Git.clone/2` passes
  `--filter=blob:none`, fetching the whole commit graph and omitting historical
  file contents. Every metric here reads the commit graph; the only thing
  needing historical contents is the size of recent commits, which git fetches
  lazily on demand.

  This is what the repository size guard was really costing. Measured, with a
  working tree:

  ```
  jest      316 MB -> 103 MB      react  1.07 GB -> 121 MB
  pandas    416 MB -> 138 MB      django  276 MB -> 154 MB
  ```

  **The analysis is identical, not degraded.** On `pallets/click`, full and
  blobless agree exactly on commit count (3,379), distinct authors (472), last
  commit date and path-filtered logs. React analyses completely — 21,710
  commits, substantive commit date found, 2,032 contributors. This is not the
  shallow clone that would keep currency and lose contributor counts.

  `LEI_GIT_CLONE_FILTER=` (empty) restores a full clone. An airgapped
  deployment needs it: `git log --numstat` lazily fetches blobs and there is no
  upstream to fetch from.

  The cost is that first `--numstat` call, 17 ms to 4 s on a small repository,
  paid once per clone. See `docs/adr/009-blobless-clones.md`.

## 0.13.1 — 2026-10-03

### Fixed

- **One contributor's name could lose a whole repository.** `git log --author`
  is a regex, and a contributor name is data from the repository.
  `apache/arrow` has a commit authored by `[5~David Li` — a real name, from a
  terminal control sequence that got into someone's git config — and the
  unterminated `[` is an invalid character class:

  ```
  fatal: header, '[5~David Li': Unmatched [, [^, [:, [., or [=
  ```

  git exits 128, the call raises, and the analysis of the entire repository is
  lost rather than one contributor's date. `pyarrow` is in the top twenty PyPI
  packages and that is what happened to it.

  Fixed by passing `-F`, so the name is matched literally — which is what the
  function means, and what the `Co-Authored-By` search one function away
  already did.

  **Not an injection.** `Lei.Git.run/3` uses `System.cmd/3` with an argument
  list, so there is no shell and the bytes reach git as data. The bug was data
  being interpreted as a pattern.

  **It is also a correctness fix, not only a crash fix.** A name containing `.`
  is a *valid* regex where the dot matches any character, so the lookup could
  return a different person's commit:

  ```
  --author=A.C Dev        ->  2026-01-01   (matched "ABC Dev")
  -F --author=A.C Dev     ->  2020-01-01   (the actual contributor)
  ```

  Six years apart, and in the direction that makes a repository look more
  recently maintained than it is. Any contributor with an initial or a `Jr.` in
  their name was exposed. The crash was the visible case; this one was silent.

  Only the unterminated `[` raised — git uses basic regular expressions, so
  `A[1] Dev`, `Foo (Bar`, `C++ Dev`, `Jo* Smith` and `Ann? Lee` all exit 0 —
  which is why this went unnoticed until a name happened to crash.

## 0.13.0 — 2026-10-03

### Fixed

- **numpy, pandas and scipy did not resolve.** 10 of the 50 most-depended-upon
  PyPI packages failed, and the list was the core of scientific Python. PyPI
  does not normalise `project_urls` keys and the extractor matched `"Source"`
  exactly; numpy writes `source`, pandas writes `repository`, pytest-cov writes
  `Sources`. Keys are now matched case- and separator-insensitively, so
  `Source Code`, `source-code` and `source_code` are one key. 80% → 96%.

  It failed as `:no_repository`, which reads as "this package declares no
  repository" rather than "we did not look properly", so the gap looked like a
  property of PyPI rather than a bug in us.

  Still deliberately narrow: only source-like keys count. Accepting any
  repository-looking value would resolve a package to whatever GitHub project
  its documentation points at — a confident analysis of the wrong history.

- **A GitHub Pages homepage now maps to its repository.** Pages serves
  `<owner>.github.io/<repo>/` from that repository, so the first path segment
  *is* the repository name. Three of the 34 genuine top RubyGems — `coveralls`,
  `vcr`, `guard` — declare no `source_code_uri` at all and only a Pages
  homepage. Applied to PyPI and Composer homepages too.

  A bare `<owner>.github.io` is **not** mapped: that is a user or organisation
  page whose repository is the website, not the package's source. It is a valid
  repository shape, so it would pass every downstream check and resolve the
  package to its own marketing site.

## 0.12.0 — 2026-10-03

### New

- **Go, Composer and RubyGems resolve.** `Lei.PackageRepository` understood npm,
  hex, pypi and cargo, which is why a customer scanning a Go service got nothing
  from us. Go needs no request at all — a module path is its location, and
  `normalize/1` already trims a `/v2` major version, a `/service/s3` submodule
  path and anything on a host we cannot clone. Composer reads
  `repo.packagist.org`'s declared `source.url`; RubyGems reads
  `source_code_uri`, which commonly points at a tag
  (`.../rails/tree/v8.1.4`) and is trimmed to the repository.

  **Two vanity prefixes are mapped**, because measuring showed they are not a
  rounding error. Of the 100 most-depended-upon Go modules, 70 are already
  `github.com/...`, 12 are `golang.org/x/...` and 4 are `gopkg.in/...`, so the
  two documented conventions take Go coverage from 70% to 86%:
  `golang.org/x/NAME` is `github.com/golang/NAME`, and gopkg.in's own scheme
  makes `pkg.vN` into `github.com/go-pkg/pkg` with the major version in the
  segment rather than a directory, so `yaml.v2` and `yaml.v3` are one
  repository. Every target was checked against the GitHub API.

  The reason is not the 16 points. `golang.org/x/*` is the Go team's own
  foundational set, so excluding it is not random missingness — it removes the
  best-maintained corner of the ecosystem and biases any measurement of Go
  toward looking worse maintained than it is. A bias that flatters the
  hypothesis is the one to remove first.

  The remaining 14% — `google.golang.org`, `k8s.io`, `go.uber.org`,
  `cloud.google.com`, `sigs.k8s.io` — stays refused. Each has a real GitHub home
  (`google.golang.org/protobuf` is `github.com/protocolbuffers/protobuf-go`) but
  no rule derives it from the path; they are per-organisation facts, and a
  confident analysis of the wrong history is worse than a refusal.

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
