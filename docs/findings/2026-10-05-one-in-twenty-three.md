# One dependency in twenty-three looks maintained and is not

**Measured 2026-10-04 · lowendinsight 0.13.1 · 461 packages across five ecosystems**

The commodity signal for whether a dependency is still maintained is the date of
its last commit. Everyone has it, and for one package in twenty-three it is
wrong — not approximately, but by years.

Of 461 of the most-depended-upon packages in npm, PyPI, Go, Packagist and
RubyGems, **20 had a commit within the last year and no commit carrying
information for over a year**. A bot bump, a dependency update, a CI tweak, a
README fix: each one refreshes the last-commit date and tells you nothing about
whether anyone is still looking after the code.

**17 of the 20 carry no known vulnerability.** So neither a CVE scanner nor a
freshness check reports anything about them.

## The twenty

`last functional commit` is the time since the last commit that changed
behaviour, excluding bot authors and documentation- or metadata-only changes.
Each row links to the analysis on our public instance, which you can read
without an account and check against the repository yourself.

| package | ecosystem | last commit | last functional commit | known CVEs | analysis |
|---|---|---|---|---|---|
| `github.com/pkg/errors` | go | 27w | **302w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fpkg%2Ferrors) |
| `coveralls` | npm | 38w | **274w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fnickmerwin%2Fnode-coveralls) |
| `eslint-config-airbnb` | npm | 32w | **218w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fairbnb%2Fjavascript) |
| `default-require-extensions` | npm | 2w | **208w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Favajs%2Fdefault-require-extensions) |
| `eslint-config-standard` | npm | 46w | **157w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fstandard%2Feslint-config-standard) |
| `shellingham` | pypi | 29w | **153w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fsarugaku%2Fshellingham) |
| `github.com/golang/protobuf` | go | 2w | **134w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fgolang%2Fprotobuf) |
| `chownr` | npm | 44w | **130w** | 1 | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fisaacs%2Fchownr) |
| `nyholm/psr7` | packagist | 44w | **129w** | 1 | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2FNyholm%2Fpsr7) |
| `import-local` | npm | 2w | **114w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fsindresorhus%2Fimport-local) |
| `restore-cursor` | npm | 2w | **114w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fsindresorhus%2Frestore-cursor) |
| `husky` | npm | 28w | **97w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Ftypicode%2Fhusky) |
| `composer/installers` | packagist | 13w | **96w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fcomposer%2Finstallers) |
| `ipython-pygments-lexers` | pypi | 4w | **89w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fipython%2Fipython-pygments-lexers) |
| `fakerphp/faker` | packagist | 34w | **84w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2FFakerPHP%2FFaker) |
| `gulp` | npm | 33w | **69w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fgulpjs%2Fgulp) |
| `colorama` | pypi | 20w | **64w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Ftartley%2Fcolorama) |
| `phpstan/extension-installer` | packagist | 8w | **56w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fphpstan%2Fextension-installer) |
| `has-ansi` | npm | 2w | **55w** | 1 | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fchalk%2Fhas-ansi) |
| `p-try` | npm | 2w | **54w** | none | [report](https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fsindresorhus%2Fp-try) |


## What this does and does not mean

**It is not a list of bad packages.** A small, complete library can be correct
and finished; dormancy may be the right state for it. `p-try` is four lines of
code that does one thing. None of the twenty is archived or disabled on GitHub —
checked, not assumed — so none of them is telling you it is done. That is the
point: the signal everyone reads says *active*, and the repository is not.

**What it means for a consuming project** is that the check you are probably
doing — last commit date, or a vulnerability scan, or both — would class all
twenty as fine. A review that wants to know whether someone is still home has
to look at what the commits changed, not when they landed.

## Method

- Packages ranked by `dependent_packages_count` from
  [ecosyste.ms](https://packages.ecosyste.ms), top 100 per ecosystem, with
  registry entries that have been removed or that nothing depends on excluded.
- Each resolved to a repository and analysed with
  [lowendinsight](https://github.com/kitplummer/lowendinsight) 0.13.1.
- Vulnerabilities cross-referenced against [OSV](https://osv.dev) by package and
  ecosystem.
- `functional_commit_currency_weeks` is the measure; `commit_currency_weeks` is
  the commodity one. The 20 are the rows where the first exceeds 52 weeks and
  the second does not.

Reproduce any single row with:

```
curl -s https://lowendinsight.dev/url=https%3A%2F%2Fgithub.com%2Fpkg%2Ferrors
```

## Limits worth knowing

- **This is the head of five popularity curves, not a sample of open source.**
  The hundredth PyPI package has 1,518 dependents; the hundredth npm package has
  41,283. The ecosystems are cut at very different depths and the figures should
  not be compared between them.
- **Large repositories are missing.** 34 of the 534 packages examined were too
  large for the analyser's size limit, among them React, TypeScript, Jest,
  DefinitelyTyped, pandas and Django. They are excluded for being large, which
  correlates with being active, so the remainder is biased toward looking worse
  maintained than the population.
- **One run, no variance estimate.** An earlier run of the same npm group
  resolved 87 packages where this one resolved 85. Single-point rates here
  should not be read to a decimal.
- **52 weeks is a threshold we chose.** It is not derived from anything.
- **The ratio claim that was in an earlier draft of this work is withdrawn.**
  Comparing risk between packages with and without a known CVE appeared to show
  a large effect; it did not survive adjustment for project size, which is the
  dominant predictor. Project size, not CVE status, is what correlates with
  staleness in these data.

## The metric

`functional_commit_currency` is in lowendinsight from 0.11.0, alongside the
commodity `commit_currency`. Both are in every report, so the gap above is
visible on any repository you analyse — including yours.
