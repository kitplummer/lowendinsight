defmodule LeiService.CacheBaseline do
  @moduledoc """
  The arithmetic behind `mix lei.cache_baseline`, separated from its IO so it
  can be tested without the network.

  The task fetches SBOMs, resolves coordinates and probes the cache. This module
  does the two things a defect would quietly corrupt: turning an SBOM into the
  package coordinates it names, and turning resolutions and cache answers into
  rates. Both have a wrong answer that looks plausible -- a manifest credited
  with a hit for itself, a hit rate of 100% over four resolved packages -- so
  both are exercised directly.
  """

  # Purl ecosystem names are not resolver names: a Go package is `golang` in a
  # purl and `go` to the resolver. Mapping them here, and taking the resolvable
  # set from the library rather than keeping a copy -- this module held its own
  # list of four, so adding Go, Composer and RubyGems to the library left the
  # survey still refusing them.
  @purl_to_resolver %{
    "npm" => "npm",
    "hex" => "hex",
    "pypi" => "pypi",
    "cargo" => "cargo",
    "golang" => "go",
    "composer" => "composer",
    "gem" => "gem"
  }

  # Purl types that name a repository outright: no registry lookup needed.
  @direct %{
    "github" => "https://github.com",
    "githubactions" => "https://github.com",
    "gitlab" => "https://gitlab.com",
    "bitbucket" => "https://bitbucket.org"
  }

  def registries, do: Map.keys(@purl_to_resolver)
  def direct, do: @direct
  def supported_ecosystems, do: Map.keys(@purl_to_resolver) ++ Map.keys(@direct)

  @doc """
  Start only what the task actually needs.

  `Mix.Task.run("app.start")` boots lei_service, which wants Postgres, Redis and
  -- under MIX_ENV=prod -- LEI_JWT_SECRET and the rest. The scheduled measurement
  runs on a CI runner with none of those. It raised there on 2026-09-28, `| tee`
  swallowed the exit status, and the job reported success having measured
  nothing: the failure shape this whole measurement was built to avoid, in the
  thing built to avoid it.

    * `:redis` - the local cache is being probed, so the app has to be up.
    * `:http` - the probe is an HTTP call to a deployed service. Nothing local is
      needed but configuration and an HTTP client, so nothing local is started.

  Returns `:ok`. Raises if what it does need will not start, rather than
  proceeding to fail obscurely later.
  """
  @spec boot(:redis | :http) :: :ok
  def boot(:redis) do
    Mix.Task.run("app.start")
    :ok
  end

  def boot(:http) do
    Mix.Task.run("loadpaths")

    # Loaded, not started: Application.get_env needs the app loaded for the
    # analyzer's thresholds and the cache TTL to resolve to their configured
    # values rather than to defaults.
    Enum.each([:lowendinsight, :lei_service], fn app ->
      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, ^app}} -> :ok
        {:error, reason} -> raise "could not load #{app}: #{inspect(reason)}"
      end
    end)

    # :temp is started because AnalyzerModule calls Temp.track!/0, and :httpoison
    # for the registries and the probe.
    Enum.each([:httpoison, :temp], fn app ->
      {:ok, _} = Application.ensure_all_started(app)
    end)

    :ok
  end

  @doc """
  The package coordinates an SPDX SBOM names, excluding the repository itself.

  GitHub's dependency-graph SBOM lists the subject repository as a package of
  itself (`com.github.owner/repo`). Counting it would credit every manifest
  measured with one guaranteed hit, since the subject is exactly the repository
  most likely to be in our cache already.
  """
  @spec packages(map(), String.t()) :: [map()]
  def packages(sbom, repo) do
    self_name = "com.github." <> String.downcase(repo)

    get_in(sbom, ["sbom", "packages"])
    |> List.wrap()
    |> Enum.reject(&(String.downcase(to_string(&1["name"])) == self_name))
    |> Enum.flat_map(&purls/1)
    |> Enum.flat_map(&coordinate(&1, repo))
  end

  defp purls(package) do
    Map.get(package, "externalRefs", [])
    |> List.wrap()
    |> Enum.filter(&(&1["referenceType"] == "purl"))
    |> Enum.map(& &1["referenceLocator"])
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  `pkg:type/namespace/name@version` to `%{ecosystem:, package:}`, or `[]`.

  The namespace is kept as part of the name. Dropping it made every
  `pkg:githubactions/actions/checkout` resolve to `checkout`, which is not a
  repository, and the whole ecosystem reported 0% coverage while looking like a
  measurement rather than a bug.
  """
  @spec coordinate(String.t(), String.t()) :: [map()]
  def coordinate(purl, from) do
    case Regex.run(~r{^pkg:([^/]+)/(.+?)(?:@[^/@]*)?$}, purl) do
      [_, type, rest] ->
        [%{ecosystem: type, package: URI.decode(rest), purl: purl, from: from}]

      _ ->
        []
    end
  end

  @doc """
  Where a coordinate's repository comes from: `{:direct, url}` for a purl type
  that names one, `{:registry, ecosystem, package}` for one that needs a lookup,
  or `{:error, reason}`.
  """
  @spec route(map()) ::
          {:direct, String.t()} | {:registry, String.t(), String.t()} | {:error, term()}
  def route(%{ecosystem: type, package: package}) do
    case Map.fetch(@direct, type) do
      {:ok, host} ->
        case String.split(package, "/") do
          [owner, repo | _] -> {:direct, "#{host}/#{owner}/#{repo}"}
          _ -> {:error, :no_repository}
        end

      :error ->
        case Map.fetch(@purl_to_resolver, type) do
          {:ok, resolver} -> {:registry, resolver, package}
          :error -> {:error, {:unsupported_ecosystem, type}}
        end
    end
  end

  @doc """
  Whether a resolution failure means "this package has no repository" or "we
  failed to ask".

  A transient failure understates coverage, and understated coverage reads as a
  finding about the ecosystem rather than about our network. They are counted
  apart so a run degraded by rate limiting cannot be mistaken for a measurement.
  """
  @spec failure_kind(term()) :: :absent | :transient
  def failure_kind(:no_repository), do: :absent
  def failure_kind(:not_found), do: :absent
  def failure_kind({:unsupported_ecosystem, _}), do: :absent
  def failure_kind({:unreachable, _}), do: :transient
  # A resolver that raised tells us nothing about the package. Counting it as
  # "no repository" would blame the ecosystem for our own bug -- and this one was
  # real: npm's string `repository` form raised until 2026-09-28.
  def failure_kind({:crashed, _}), do: :transient
  def failure_kind({:status, status}) when status in [408, 429] or status >= 500, do: :transient
  def failure_kind({:status, _}), do: :absent
  def failure_kind(_other), do: :transient

  @doc """
  Resolve every coordinate, and survive the ones that do not resolve.

  `on_timeout: :kill_task`, not the default `:exit`. Found on 2026-09-28: one
  registry request that outlasted the per-element timeout ended a forty-minute
  run over fifteen thousand coordinates at the last step, after every SBOM had
  been fetched. The default kills the stream and therefore the measurement.

  `zip_input_on_exit` for the same reason -- without it the entry that failed is
  not in the result, so the counts silently lose a package rather than recording
  one we could not look up.

  A coordinate we could not resolve is a data point. It is recorded as
  `{:crashed, reason}`, which `failure_kind/1` calls transient: our failure, not
  a fact about the package.
  """
  @spec resolve_all([map()], (map() -> term()), keyword()) :: [map()]
  def resolve_all(entries, resolve, opts \\ []) do
    entries
    |> Task.async_stream(fn entry -> Map.put(entry, :repository, attempt(resolve, entry)) end,
      max_concurrency: Keyword.get(opts, :concurrency, 8),
      timeout: Keyword.get(opts, :timeout, 180_000),
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, {entry, reason}} -> Map.put(entry, :repository, {:error, {:crashed, reason}})
    end)
  end

  # A raise inside Task.async_stream is not an {:exit, _} the stream reports: the
  # task is linked, so it takes the caller with it and no option changes that.
  # Only on_timeout is configurable. So the raise is caught here, where it costs
  # one coordinate instead of the run -- which is how npm's string `repository`
  # field ended a measurement at coordinate 900 of 16,000.
  defp attempt(resolve, entry) do
    try do
      case resolve.(entry) do
        {:ok, url} when is_binary(url) ->
          {:ok, url}

        {:error, reason} ->
          {:error, reason}

        # Loud, because the alternative is storing it and counting the coordinate
        # as unresolved -- which is exactly how a resolver returning the entry
        # instead of the resolution produced a run that resolved nothing and
        # still printed rates.
        other ->
          raise ArgumentError,
                "resolver returned #{inspect(other)}; expected {:ok, url} or {:error, reason}"
      end
    rescue
      error -> {:error, {:crashed, Exception.message(error)}}
    catch
      kind, reason -> {:error, {:crashed, {kind, reason}}}
    end
  end

  @doc """
  Counts and rates over resolved entries, against the set of cached URLs.

  Entries are `%{ecosystem:, package:, repository: {:ok, url} | {:error, reason}}`.
  """
  @spec counts([map()], MapSet.t()) :: map()
  def counts(entries, cached) do
    distinct = Enum.uniq_by(entries, &{&1.ecosystem, &1.package})
    {ok, failed} = Enum.split_with(distinct, &match?({:ok, _}, &1.repository))

    # Packages and repositories are different denominators and the first version
    # used one for both. Many packages resolve to one repository -- a monorepo,
    # or a project publishing per-platform builds -- so unique URLs came out far
    # below distinct packages and the gap was reported as coverage. It read as
    # "we cannot resolve a third of npm" when the real figure was a few percent.
    # Coverage is per package; the hit rate is per repository, because a
    # repository is what gets cloned and cached.
    repositories = ok |> Enum.map(fn %{repository: {:ok, url}} -> url end) |> Enum.uniq()
    hits = Enum.count(repositories, &MapSet.member?(cached, &1))

    failures =
      Enum.frequencies_by(failed, fn %{repository: {:error, reason}} -> failure_kind(reason) end)

    %{
      packages: length(distinct),
      resolved_packages: length(ok),
      repositories: length(repositories),
      no_repository: Map.get(failures, :absent, 0),
      lookup_failed: Map.get(failures, :transient, 0),
      hits: hits,
      misses: length(repositories) - hits,
      hit_rate: rate(hits, length(repositories)),
      coverage: rate(length(ok), length(distinct))
    }
  end

  # nil, not 0.0. "No packages, so no rate" and "packages, none cached" are
  # different findings and must not print alike -- a run that resolved nothing
  # reporting 0.0% is this codebase's failure shape, a number where there is no
  # measurement.
  def rate(_n, 0), do: nil
  def rate(n, total), do: Float.round(n * 100 / total, 1)

  @doc """
  The whole run, ready to print or to write as JSON for comparison with a later
  one.
  """
  @spec summarise([map()], MapSet.t(), [String.t()], map(), [String.t()]) :: map()
  def summarise(resolved, cached, repos_read, repos_failed, ecosystems) do
    %{
      measured_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      repos_read: repos_read,
      repos_failed: repos_failed,
      ecosystems_considered: ecosystems,
      overall: counts(resolved, cached),
      by_ecosystem:
        resolved
        |> Enum.group_by(& &1.ecosystem)
        |> Map.new(fn {ecosystem, entries} -> {ecosystem, counts(entries, cached)} end),
      unresolved_reasons: unresolved_reasons(resolved),
      unresolved: unresolved(resolved),
      repositories_missing: missing(resolved, cached)
    }
  end

  @doc """
  The repositories a real manifest depends on that we do not hold.

  This is the output the measurement exists to produce, beyond the rate itself:
  the work a preload would have to do, and the population to sample when costing
  it. A count alone cannot be sampled, and a cost model built on a sample of
  something else -- fifteen repositories chosen by hand, say -- is a cost model
  for a different corpus. History size drives the clone here, not project size,
  so which repositories are in it matters.
  """
  @spec missing([map()], MapSet.t()) :: [String.t()]
  def missing(resolved, cached) do
    resolved
    |> Enum.filter(&match?({:ok, _}, &1.repository))
    |> Enum.map(fn %{repository: {:ok, url}} -> url end)
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(cached, &1))
  end

  defp unresolved_reasons(resolved) do
    resolved
    |> Enum.uniq_by(&{&1.ecosystem, &1.package})
    |> Enum.reject(&match?({:ok, _}, &1.repository))
    |> Enum.frequencies_by(fn %{repository: {:error, reason}} -> inspect(reason) end)
  end

  # The coordinates themselves, not just a count. 200 unresolved npm packages is
  # either a fact about npm or a bug in our resolver, and the count alone cannot
  # tell you which.
  defp unresolved(resolved) do
    resolved
    |> Enum.uniq_by(&{&1.ecosystem, &1.package})
    |> Enum.reject(&match?({:ok, _}, &1.repository))
    |> Enum.map(fn %{repository: {:error, reason}} = entry ->
      %{ecosystem: entry.ecosystem, package: entry.package, reason: inspect(reason)}
    end)
  end
end
