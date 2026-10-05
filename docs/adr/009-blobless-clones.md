# ADR-009: What the size limit measures

**Status:** Proposed
**Date:** 2026-10-05
**Authors:** Kit Plummer, Claude (AI pair)
**Relates to:** ADR-003 (the library/service split, and the airgapped
deployment), ADR-008 (storage and scale)

## Context

`Lei.RepoSize` refuses a repository over `max_repo_size_kb`, 250 MB by default.
The number is empirical: #162 found that a 1 GB limit on a machine with 459 MB
of memory let 671 MB and 411 MB repositories through, and #158 was an OOM kill
while analysing large repositories. The production machine is 1 CPU and 512 MB
of memory; the root filesystem has 7.3 GB free, no volume and no quota, and five
analyses can be in flight at once. **Memory is the binding constraint and disk
is not** — five concurrent 250 MB clones is 1.25 GB against 7.3 GB.

The guard is right to exist. What it measures is wrong.

### It compares a number that counts the wrong bytes

The comparison is against GitHub's `size` field, which counts **every revision
of every file**. Every metric this library produces comes from the commit graph:
dates, authors, the paths a commit touched. File contents are needed for exactly
one thing, the size of recent commits.

A `--filter=blob:none` clone fetches the whole commit graph and omits file
contents. Measured on 2026-10-05:

| repository | full | blobless | against the 250 MB limit |
|---|---|---|---|
| `facebook/react` | ~1.07 GB | **47 MB** | under |
| `jestjs/jest` | 316 MB | **29 MB** | under |
| `pandas-dev/pandas` | 416 MB | **58 MB** | under |
| `django/django` | 276 MB | **69 MB** | under |
| `DefinitelyTyped` | 809 MB | **220 MB** | under |
| `pytorch/pytorch` | 1.59 GB | 258 MB | over, barely |
| `microsoft/TypeScript` | 2.89 GB | 1.2 GB | over |

Five of the seven largest exclusions come under the **existing** limit with no
change to it. Those five are React, Jest, DefinitelyTyped, pandas and Django —
the packages `docs/findings/2026-10-05-one-in-twenty-three.md` has to list as
unanalysable, in the two ecosystems most projects actually use.

### It is not the shallow-clone trade `Lei.RepoSize` rejects

The module declines to degrade rather than refuse, and is right to:

> A shallow clone would bound the fetch and produce *an* answer with different
> meaning: commit currency would survive, contributor counts and functional
> contributors would not. Half a report presented as a report is the failure
> this codebase produces most often.

**That objection does not apply to a blobless clone**, which keeps the entire
commit graph. Measured on `pallets/click`, full against blobless:

```
commits              3379  /  3379
distinct authors      472  /   472
last commit date   identical
log -1 -- '*.py'   identical          <- what functional currency reads
```

Nothing is approximated. The two clones answer every question this library asks
of git identically, because the data those questions read is fully present.

## The decision

**Clone blobless, and compare the limit against what a blobless clone actually
costs rather than against GitHub's `size`.**

Two parts, and the second is the one that matters: the guard should keep
protecting memory, but it should measure the thing being fetched. GitHub's
`size` would remain the cheap pre-check — it is one API call and no bytes — but
as an upper bound to reject on only when even the blobless figure cannot
plausibly fit, not as the figure itself.

## The cost, measured

`git log --numstat` is the one thing that needs file contents, and on a blobless
clone it lazily fetches them:

```
full      17 ms
blobless  4021 ms       first call, fetching what it needs
blobless    23 ms       subsequently, network unavailable
```

So the cost is paid once per clone, not per call. Three consequences:

**Analysis makes network calls mid-run.** Today a clone completes and the
analysis is local. This moves part of the fetch into the analysis, where a
network failure produces a different and later error.

**An airgapped deployment breaks** unless the blobs `--numstat` needs are
fetched during the clone. ADR-003 makes self-hosting a first-class case, and a
UDS bundle has no upstream to lazily fetch from. Either the clone pre-fetches
what the analysis will read, or blobless is a configuration rather than the
default.

**The four seconds is on `click`, a small repository.** It is not measured on
anything in the table above, and it is the number most likely to be worse at
the scale this is meant to unlock.

## Options

| | effect |
|---|---|
| **Blobless with a bounded `--numstat` window** | restrict large-commit detection to a recent window, so the lazy fetch is small and predictable. Changes what "large recent commits" means, which is a reportable change rather than a silent one. |
| **Blobless, pre-fetching at clone time** | keeps the analysis local and the airgap intact. Costs whatever the pre-fetch costs, unmeasured. |
| **Blobless as opt-in** | default unchanged, hosted service enables it, self-hosted and airgapped keep the full clone. Two paths to maintain, and the hosted path becomes the one nobody self-hosting has exercised. |
| **Leave it** | React, TypeScript, Jest, DefinitelyTyped, pandas and Django stay unanalysable, which the published finding already discloses as a limitation. |

The first is the smallest change that unlocks the five repositories, and it is
the one that alters a reported metric. That trade — a narrower
`large_recent_commits` window in exchange for analysing React and pandas at all
— is the decision, and it is not ours to make silently: the metric is in every
report.

## Consequences

- The `max_repo_size_kb` figure stops meaning "GitHub says this repository is
  this big" and starts meaning "this is what we will fetch". Those differ by
  roughly 10x on the repositories that matter.
- `docs/findings/2026-10-05-one-in-twenty-three.md` states the exclusion as a
  limitation and a bias. If this is adopted, the measurement should be re-run
  before that limitation is restated, because the excluded repositories are
  large and therefore likely active -- their absence biases the finding toward
  looking worse maintained.
- The guard still covers GitHub and nothing else. `Lei.RepoSize` is explicit
  that a host without a size API passes through unmeasured, and bounding the
  clone itself remains the only thing that would cover the rest. Blobless makes
  that bound cheaper to impose but does not impose it.

## Not verified

- **The lazy-fetch cost on a large repository.** Four seconds is `click`.
  Nothing in the table was measured for `--numstat`.
- **Whether the analyser runs end to end on a blobless clone.** The git-level
  queries were compared and match; `AnalyzerModule` was not driven against one,
  so the equivalence is established at the layer below the one that matters.
- **Memory during analysis of a blobless clone of a large repository.** The
  limit exists because of an OOM, and this ADR argues the fetch is smaller
  without measuring what analysing React costs on a 512 MB machine. That is the
  measurement that would decide it, and it has not been taken.
