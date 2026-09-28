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

  # Registry purl types `Lei.PackageRepository` can resolve.
  @registries ~w(npm hex pypi cargo)

  # Purl types that name a repository outright: no registry lookup needed.
  @direct %{
    "github" => "https://github.com",
    "githubactions" => "https://github.com",
    "gitlab" => "https://gitlab.com",
    "bitbucket" => "https://bitbucket.org"
  }

  def registries, do: @registries
  def direct, do: @direct
  def supported_ecosystems, do: @registries ++ Map.keys(@direct)

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
        if type in @registries do
          {:registry, type, package}
        else
          {:error, {:unsupported_ecosystem, type}}
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
  def failure_kind({:status, status}) when status in [408, 429] or status >= 500, do: :transient
  def failure_kind({:status, _}), do: :absent
  def failure_kind(_other), do: :transient

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
      unresolved: unresolved(resolved)
    }
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
