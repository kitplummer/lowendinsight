# LowEndInsight for VS Code

> **Beta.** This extension and the LowEndInsight service are in beta. Settings,
> commands and results may change between betas.

LowEndInsight measures the maintenance risk of the repositories behind your
dependencies: how many people actually maintain them, how recently anyone
committed, and whether one large recent commit rewrote most of the code. A
dependency maintained by one person who stopped a year ago is a risk no
vulnerability scanner reports.

The extension reads your manifests, asks the [LowEndInsight
service](https://lowendinsight.dev) about each dependency, and shows the answer
where you work:

- **Diagnostics** on the manifest line of every high or critical dependency
- **Hovers** with the contributor, currency and large-commit metrics
- **A Dependency Risk view** grouped by risk, with a **Not analysed** group
  that says why for anything without a result
- **A status bar summary**, counting what was not analysed as well as what was

## Getting started

1. Get an API key at <https://lowendinsight.dev/signup>. It is **free during the
   beta**, up to 60 requests a minute.
2. Run **LEI: Set API Key** and paste it. The key is kept in VS Code's secret
   storage, not in `settings.json`.
3. Run **LEI: Analyze Dependencies**, or let it run when a manifest changes.

Until a key is set, nothing is sent anywhere.

## What it reads

| Manifest | Ecosystem |
|---|---|
| `package.json` | npm |
| `mix.exs` | Hex |
| `Cargo.toml` | crates.io |
| `go.mod` | Go modules |
| `requirements.txt` | PyPI |
| `Gemfile` | RubyGems |
| `pom.xml`, `build.gradle` | read, but **not yet supported** by the service; listed as not analysed |

Dependencies are sent by name; the service finds each one's repository through
its registry. A dependency that names a git repository directly is analysed by
that URL.

## Privacy

With a key set and **LowEndInsight: Auto Analyze** on (the default), the names
and version ranges of your manifests' dependencies are sent to the service at
`lowendinsight.apiUrl` when a workspace opens and when a manifest changes. Turn
auto-analysis off to send them only when you run a command.

## Settings

| Setting | Default | |
|---|---|---|
| `lowendinsight.apiUrl` | `https://lowendinsight.dev` | Change only for a self-hosted deployment |
| `lowendinsight.autoAnalyze` | `true` | Analyse on open and on manifest change, once a key is set |

## A new dependency shows as "still being analysed"

The first request for a dependency nobody has asked about queues its analysis,
which clones the repository. The extension waits up to two minutes; anything
still running after that is listed as pending. Run **LEI: Analyze
Dependencies** again shortly.

Source and issues: <https://github.com/kitplummer/lowendinsight>
