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
while analysing large repositories. Measured on the machine itself rather than
read from the Fly API, which reports the allocation and not what the guest sees:

```
/ on overlay (vda/vdc)      7.8 GB total, 7.3 GB free, no volume, no quota
/tmp                        the same filesystem -- not a tmpfs
Mem:                        459 MB total, 256 MB available, swap 0
```

**Memory is the binding constraint and storage is not.** Five concurrent 250 MB
clones is 1.25 GB against 7.3 GB free, under 20% utilisation; there is room for
roughly 29 of them. Clones land on real disk, so clone size and memory are
separate budgets rather than the same one.

The memory figure is tighter than the API suggests. Fly reports `memory_mb:
512`; the guest reports **459 MB total and 256 MB available**, and **swap is
zero**, so exceeding it is an OOM kill rather than a slowdown. That is what #158
was. 459 MB is also the exact figure `Lei.RepoSize` cites from #162 -- the guard
has always been a memory proxy, and it reads a disk number to protect a memory
budget.

The guard is right to exist. What it measures is wrong.

### It compares a number that counts the wrong bytes

The comparison is against GitHub's `size` field, which counts **every revision
of every file**. Every metric this library produces comes from the commit graph:
dates, authors, the paths a commit touched. File contents are needed for exactly
one thing, the size of recent commits.

A `--filter=blob:none` clone fetches the whole commit graph and omits file
contents. Measured on 2026-10-05, **with a working tree**, because the analyser
reads files for the manifest and SBOM scan:

| repository | full | blobless, checked out | against the 250 MB limit |
|---|---|---|---|
| `jestjs/jest` | 316 MB | **103 MB** | under |
| `facebook/react` | ~1.07 GB | **121 MB** | under |
| `pandas-dev/pandas` | 416 MB | **138 MB** | under |
| `django/django` | 276 MB | **154 MB** | under |
| `pytorch/pytorch` | 1.59 GB | 613 MB | over |
| `DefinitelyTyped` | 809 MB | 805 MB | over |
| `microsoft/TypeScript` | 2.89 GB | 1.62 GB | over |

**An earlier draft of this ADR measured `--no-checkout` and was wrong about two
rows.** Bare, React is 47 MB and DefinitelyTyped 220 MB; with the working tree
the analyser needs, they are 121 MB and 805 MB. DefinitelyTyped barely shrinks
at all, because it is almost entirely small text files and the working tree *is*
the bulk. Correcting that moves it from "under" to "over" and takes the win from
five repositories to four.

Four of the seven largest exclusions come under the **existing** limit with no
change to it: React, Jest, pandas and Django — in the two ecosystems most
projects actually use, and four of the packages
`docs/findings/2026-10-05-one-in-twenty-three.md` has to list as unanalysable.
TypeScript, pytorch and DefinitelyTyped stay out either way.

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

### The clone was never the binding constraint

React analyses **completely and correctly** from a blobless clone. Driven on
2026-10-05 through `AnalyzerModule.analyze/3` against a `file://` URL:

```
total_commits_on_default_branch  21710
last_substantive_commit_date     2026-10-02   source: :found
contributor_risk                 low
functional_contributors_risk     low
human_contributor_count          2032
human_functional_contributors    103
agentic_contribution_ratio       0.1035
total_file_count                 7751
```

Nothing is missing and nothing is approximated. But measuring peak resident
memory while doing it moved the problem:

| | commits | peak RSS | attributable to the analysis | wall |
|---|---|---|---|---|
| BEAM + mix, nothing analysed | — | 120 MB | — | 0.4 s |
| `pallets/click` | 3,379 | 133 MB | 13 MB | 1.0 s |
| `facebook/react` | 21,710 | **222 MB** | **102 MB** | 13.6 s |

Analysis memory tracks commit count, not repository size. On the production
machine, five React-scale analyses need roughly `120 + 5 x 102 = 630 MB`.
Against **256 MB available** that is not close: a single React-scale analysis is
already 40% of the headroom, and two concurrent would about exhaust it. **That
is the OOM the size limit was protecting against**, and blobless does not remove
it; it removes the clone barrier and exposes this one underneath.

So the 250 MB figure is a *proxy* for analysis memory. The proxy is wrong about
which bytes it counts — off by roughly 10x on the repositories that matter — and
roughly right about the ceiling it implies. Both of those are true at once, and
only the first is fixed by cloning differently.

### An aside that belongs with it

The React report carries `repo_size: "0"`. The adversarial review of the study
dataset found the same thing: `repo_size_kb` is the string `"0"` on all 461
determined rows. The field that should measure the thing this limit cares about
measures nothing. Not a blocker here, and it means any future gate on *measured*
clone size has to start by fixing it.

## The decision

Two changes, and the second is the decision:

**1. Clone blobless.** One flag. It takes React, Jest, pandas and Django from
unanalysable to analysable with no change to the limit, and the analysis is
verified correct rather than degraded. This part is uncontroversial.

**2. Decide the concurrency-versus-size trade, because that is the real
ceiling.** 102 MB of analysis for React against 256 MB available and five
slots. The options:

| | effect |
|---|---|
| **A larger machine** | 1 GB would hold two or three React-scale analyses; 2 GB would hold five with room. Costs money, monthly, and is the only option that changes nothing else. |
| **A separate queue for large repositories, concurrency 1 or 2** | keeps the machine, bounds the worst case, and makes a large analysis wait behind other large ones rather than failing. More Oban configuration, and ADR-004 is where that belongs. |
| **A per-analysis memory budget** | the analyser would have to bound what it holds -- the agentic contributor list for React is 2,032 entries -- which is real work in the library and the only option that helps a self-hosted deployment on a small machine. |
| **Keep a size cap, measured properly** | gate on commit count, which is what analysis memory actually tracks, instead of GitHub's `size`. Cheap, honest, and still excludes repositories we could analyse one at a time. |

The last two compose: bound what an analysis holds, and gate on the thing that
predicts it. The first two buy time without learning anything.

**What this ADR does not decide** is which. That is a cost question as much as a
technical one, and the measurement above is what it should be decided on rather
than on the 250 MB figure, which was never about the clone.

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

## What to do about `--numstat`

The lazy fetch above is the one thing that needs file contents, and it has three
possible answers:

| | effect |
|---|---|
| **Bound the window** | restrict large-commit detection to recent history, so the fetch is small and predictable. Changes what `large_recent_commits` means -- a reportable change, since the metric is in every report. |
| **Pre-fetch at clone time** | keeps the analysis local and the airgap intact. Costs whatever the pre-fetch costs, which is unmeasured. |
| **Blobless as opt-in** | default unchanged; the hosted service enables it, self-hosted keeps the full clone. Two paths, and the hosted one becomes the path nobody self-hosting has exercised. |

Bounding the window is the smallest change, and it is the one that alters a
reported metric. That trade -- a narrower `large_recent_commits` window in
exchange for analysing React and pandas at all -- is not ours to make silently.

## Consequences

- The `max_repo_size_kb` figure stops meaning "GitHub says this repository is
  this big" and starts meaning "this is what we will fetch". Those differ by
  roughly 10x on the repositories that matter -- and neither is what the limit
  is really for, which is bounding analysis memory.
- **Four repositories become analysable and three do not.** TypeScript, pytorch
  and DefinitelyTyped stay excluded, so the published finding keeps a
  limitation; it gets smaller rather than going away.
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

- **Memory for the other three.** React is 102 MB of analysis at 21,710
  commits. pandas, Django and Jest were not measured, and the relationship to
  commit count is two points on a line.
- **The lazy-fetch cost on a large repository.** 4 seconds is `click`, with
  3,379 commits. Nothing in the table above was measured for `--numstat`.
- **Whether five concurrent analyses actually OOM.** The arithmetic says 630 MB
  against 256 MB available, but peak RSS of five BEAM-hosted tasks
  in one VM is not five times one task's peak -- they share a heap and the
  garbage collector is per-process. The real figure could be materially lower,
  and it is the number that decides option 1 against options 3 and 4.
- **`repo_size_kb` returning `"0"`.** Observed in the React report and across
  all 461 rows of the study dataset. Unexplained, and it is the field any
  measured-size gate would use.
