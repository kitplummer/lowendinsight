defmodule Mix.Tasks.Lei.CacheBaseline do
  @shortdoc "Measure what fraction of a real manifest is already cached"

  @moduledoc """
  The one number the pricing argument rests on, measured rather than assumed.

      mix lei.cache_baseline --repos repos.txt

  ADR-005 argues the shared cache is the asset: the five-hundredth customer
  holding `jason` costs nothing extra. That is only true at some hit rate, so the
  rate is worth measuring rather than assuming.

  For each `owner/repo` in `--repos`, this fetches GitHub's dependency-graph
  SBOM -- a *real* resolved dependency set, direct and transitive, not a
  manifest we invented -- turns each package coordinate into the repository the
  analyzer would clone, and asks the cache whether it is already there.

  ## Three numbers, and they are different

    * **hit rate** = cached / resolved. What ADR-005 means.
    * **coverage** = resolved / packages. A package whose repository we cannot
      work out is a miss from the customer's side just as surely as an uncached
      one, and it never appears in the hit rate. Reported apart so a flattering
      hit rate over a handful of resolved packages cannot hide.
    * **lookup failures**, counted separately from packages that genuinely have
      no repository. A registry that rate-limited us understates coverage, and
      that reads as a finding about npm rather than about our network.

  ## Reading the cache without filling it

  Analysing to find out would cache what it measured, so the first repository
  measured would be the last one to report honestly. Membership comes from
  `POST /v1/cache/probe` (read-only, uncharged) or, without `--probe-url`, from
  the local datastore.

  A probe that cannot reach Redis fails this task rather than counting as a
  miss: 0% from a dead cache is this codebase's recurring shape, a number where
  there is no measurement.

  ## Options

    * `--repos PATH` - one `owner/repo` (or GitHub URL) per line; `#` comments
      and blanks ignored. Required. Which repositories are worth measuring is a
      question for whoever runs this, so no list ships here.
    * `--probe-url URL` - service base URL to probe, e.g. production. Needs
      `LEI_API_KEY` with the `cache` scope. Without it the local cache is
      measured, which for a development machine is a 0% you already knew.
    * `--out PATH` - write the run as JSON, including the unresolved
      coordinates, so a later run is comparable and a bad number is diagnosable.
    * `--concurrency N` - registry lookups in flight. Default 8. Raising this
      buys wall clock and pays in lookup failures.
    * `--min-repos N` - fail if fewer than N SBOMs were read. Default 1.
    * `--max-lookup-failures PCT` - fail if more than this share of coordinates
      could not be looked up. Default 5.
    * `--ecosystems a,b` - restrict to these. Default: all of them, including
      the ones we cannot resolve, so the size of that gap is in the output.

  `LEI_GH_TOKEN` is used for the SBOM API when set; unauthenticated GitHub allows
  60 requests an hour, which does not cover 50 repositories.
  """

  use Mix.Task

  alias LeiService.CacheBaseline, as: Baseline

  @impl Mix.Task
  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          repos: :string,
          probe_url: :string,
          out: :string,
          concurrency: :integer,
          min_repos: :integer,
          max_lookup_failures: :float,
          ecosystems: :string
        ]
      )

    repos = read_repos(opts[:repos] || Mix.raise("--repos is required"))
    min_repos = opts[:min_repos] || 1
    concurrency = opts[:concurrency] || 8
    max_failures = opts[:max_lookup_failures] || 5.0

    # No filter by default, on purpose. Restricting to the ecosystems we can
    # resolve would drop every Go and Ruby package before counting it, and the
    # gap -- a customer scanning a Go service gets nothing from us -- would not
    # appear anywhere in the output. Unsupported ecosystems are counted and
    # reported as unresolved.
    ecosystems =
      case opts[:ecosystems] do
        nil -> :all
        list -> String.split(list, ",", trim: true) |> Enum.map(&String.trim/1)
      end

    # Probing a deployed service needs no local Redis, and booting the app to
    # get one is how this failed in CI.
    Baseline.boot(if opts[:probe_url], do: :http, else: :redis)

    shell().info("Reading #{length(repos)} SBOMs from GitHub...")
    {read, failed} = Enum.split_with(Enum.map(repos, &fetch_sbom/1), &match?({:ok, _, _}, &1))

    Enum.each(failed, fn {:error, repo, reason} ->
      shell().error("  #{repo}: #{inspect(reason)}")
    end)

    if length(read) < min_repos do
      Mix.raise(
        "read #{length(read)} SBOMs, needed at least #{min_repos}. " <>
          "Refusing to report a rate measured over nothing."
      )
    end

    packages =
      read
      |> Enum.flat_map(fn {:ok, repo, sbom} -> Baseline.packages(sbom, repo) end)
      |> Enum.filter(&(ecosystems == :all or &1.ecosystem in ecosystems))

    unique = Enum.uniq_by(packages, &{&1.ecosystem, &1.package})
    shell().info("#{length(packages)} package entries, #{length(unique)} distinct.")

    shell().info("Resolving #{length(unique)} coordinates to repositories...")
    resolved = Baseline.resolve_all(unique, &resolve/1, concurrency: concurrency)

    urls =
      resolved
      |> Enum.filter(&match?({:ok, _}, &1.repository))
      |> Enum.map(fn %{repository: {:ok, url}} -> url end)
      |> Enum.uniq()

    # A run that resolved nothing is a broken run, not a corpus with no
    # repositories, and it would otherwise go on to report a hit rate of n/a and
    # a coverage of 0% as though those were findings. This is how the resolver
    # contract bug above presented.
    if urls == [] and unique != [] do
      Mix.raise(
        "none of #{length(unique)} coordinates resolved to a repository. " <>
          "That is a fault here, not a fact about the corpus; refusing to report rates."
      )
    end

    shell().info("Probing #{length(urls)} repositories against the cache...")
    cached = probe(urls, opts[:probe_url])

    summary =
      Baseline.summarise(
        resolved,
        cached,
        Enum.map(read, fn {:ok, repo, _} -> repo end),
        Map.new(failed, fn {:error, repo, reason} -> {repo, inspect(reason)} end),
        if(ecosystems == :all, do: "all", else: ecosystems)
      )

    report(summary)

    if path = opts[:out] do
      File.write!(path, Jason.encode_to_iodata!(summary, pretty: true))
      shell().info("\nWrote #{path}")
    end

    check_lookup_failures(summary, max_failures)
  end

  defp shell, do: Mix.shell()

  defp read_repos(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&normalise_repo/1)
    |> Enum.uniq()
  end

  # owner/repo or a full URL, because a list harvested from a popularity ranking
  # arrives in whichever form that source used.
  defp normalise_repo(line) do
    line
    |> String.replace_prefix("https://github.com/", "")
    |> String.replace_prefix("http://github.com/", "")
    |> String.trim_trailing("/")
    |> String.trim_trailing(".git")
  end

  defp fetch_sbom(repo) do
    url = "https://api.github.com/repos/#{repo}/dependency-graph/sbom"

    headers =
      [{"User-Agent", "lowendinsight"}, {"Accept", "application/vnd.github+json"}] ++
        case System.get_env("LEI_GH_TOKEN") do
          token when is_binary(token) and token != "" -> [{"Authorization", "Bearer #{token}"}]
          _ -> []
        end

    HTTPoison.start()

    case Lei.HTTP.Retry.request(
           # follow_redirect for the same reason as GithubTrending's size
           # lookup: `/repos/{slug}/...` answers 301 for a renamed repository,
           # and without it a rename reads as "this repository publishes no
           # SBOM" rather than "we looked in the wrong place".
           fn ->
             HTTPoison.get(url, headers,
               recv_timeout: 30_000,
               follow_redirect: true,
               max_redirect: 3
             )
           end,
           max_attempts: 3,
           wait: 2_000
         ) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, repo, decoded}
          {:error, reason} -> {:error, repo, {:undecodable, reason}}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, repo, {:status, status}}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, repo, {:unreachable, reason}}
    end
  end

  # Returns the resolution, not the entry: resolve_all/3 is what attaches it.
  # This returned the entry with :repository already set, so resolve_all set
  # :repository to the whole entry, nothing matched {:ok, url}, and every
  # coordinate counted as unresolved -- "Probing 0 repositories" and a coverage
  # of 0%. It reached main green, because the tests call resolve_all with their
  # own resolver and the task's was the one nobody drove.
  defp resolve(entry) do
    case Baseline.route(entry) do
      {:direct, url} -> {:ok, url}
      {:registry, ecosystem, package} -> Lei.PackageRepository.resolve(ecosystem, package)
      {:error, reason} -> {:error, reason}
    end
  end

  defp probe([], _base), do: MapSet.new()

  defp probe(urls, nil) do
    case LeiService.Datastore.probe_cache(urls) do
      {:ok, results} ->
        for {url, true} <- results, into: MapSet.new(), do: url

      {:error, reason} ->
        Mix.raise("cache unavailable: #{inspect(reason)}. Not reporting a rate.")
    end
  end

  defp probe(urls, base) do
    key =
      System.get_env("LEI_API_KEY") || Mix.raise("--probe-url needs LEI_API_KEY (cache scope)")

    urls
    |> Enum.chunk_every(500)
    |> Enum.reduce(MapSet.new(), fn chunk, acc ->
      MapSet.union(acc, probe_chunk(chunk, String.trim_trailing(base, "/"), key))
    end)
  end

  defp probe_chunk(urls, base, key) do
    HTTPoison.start()

    request =
      HTTPoison.post(
        base <> "/v1/cache/probe",
        Jason.encode!(%{urls: urls}),
        [
          {"Content-Type", "application/json"},
          {"Authorization", "Bearer " <> key},
          {"User-Agent", "lowendinsight"}
        ],
        recv_timeout: 60_000
      )

    case request do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        %{"results" => results} = Jason.decode!(body)
        for {url, true} <- results, into: MapSet.new(), do: url

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        Mix.raise("probe returned #{status}: #{body}")

      {:error, %HTTPoison.Error{reason: reason}} ->
        Mix.raise("probe unreachable: #{inspect(reason)}")
    end
  end

  # Last, so the numbers are printed and written before the run is rejected: the
  # output is what tells you which registry stopped answering.
  defp check_lookup_failures(summary, max_failures) do
    o = summary.overall
    share = Baseline.rate(o.lookup_failed, o.packages)

    if share && share > max_failures do
      Mix.raise(
        "#{o.lookup_failed} of #{o.packages} coordinates (#{share}%) could not be looked up, " <>
          "over the #{max_failures}% limit. Coverage below is understated by our own failures, " <>
          "not by the ecosystem. Lower --concurrency and run it again."
      )
    end
  end

  defp report(summary) do
    o = summary.overall

    shell().info("""

    Cache baseline, #{summary.measured_at}
    #{length(summary.repos_read)} SBOMs read, #{map_size(summary.repos_failed)} failed

      distinct packages   #{o.packages}
      resolved to a repo  #{o.resolved_packages}   (coverage #{pct(o.coverage)})
        no repository     #{o.no_repository}
        lookup failed     #{o.lookup_failed}
      distinct repos      #{o.repositories}
      already cached      #{o.hits}
      not cached          #{o.misses}
      HIT RATE            #{pct(o.hit_rate)}
    """)

    shell().info("    per ecosystem")

    summary.by_ecosystem
    |> Enum.sort_by(fn {_e, c} -> -c.packages end)
    |> Enum.each(fn {ecosystem, c} ->
      shell().info(
        "      #{String.pad_trailing(ecosystem, 15)} " <>
          "#{String.pad_leading(to_string(c.packages), 5)} pkgs  " <>
          "hit #{String.pad_leading(pct(c.hit_rate), 6)}  " <>
          "coverage #{String.pad_leading(pct(c.coverage), 6)}  " <>
          "lookup failed #{c.lookup_failed}"
      )
    end)

    if summary.unresolved_reasons != %{} do
      shell().info("\n    unresolved")

      summary.unresolved_reasons
      |> Enum.sort_by(fn {_r, n} -> -n end)
      |> Enum.each(fn {reason, n} ->
        shell().info("      #{String.pad_leading(to_string(n), 5)}  #{reason}")
      end)
    end
  end

  defp pct(nil), do: "n/a"
  defp pct(rate), do: "#{rate}%"
end
