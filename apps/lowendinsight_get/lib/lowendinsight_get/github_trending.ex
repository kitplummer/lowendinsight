# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.GithubTrending do
  require Logger
  require HTTPoison.Retry

  @type language() :: String.t()

  @ossinsight_base "https://api.ossinsight.io/v1/trends/repos/"
  @github_search_base "https://api.github.com/search/repositories"

  # A refresh older than this is due again. The job runs hourly, so a language
  # is at most a day and an hour stale when everything is healthy.
  @refresh_after_seconds 24 * 3600

  # Held while languages are processed, so the hourly job and the manual trigger
  # (POST /v1/gh_trending/process) never analyse at the same time.
  #
  # Sized to one language, not a whole run, and extended as each language
  # completes. It was six hours: when production was OOM-killed mid-run the
  # release in `after` never happened, and the lock kept the job from running
  # for the rest of the day (#158). Now a kill costs at most this long.
  @lock_key "gh_trending_lock"
  @lock_ms 90 * 60 * 1000

  @doc """
  Refreshes every language that is due, one at a time.

  This replaced a midnight job that started every language's analysis at once,
  asynchronously. Clones of large trending repositories piled up until the
  512 MB machine ran out of memory (4 MB free for over a minute on
  2026-09-14), the process was killed, and every language was left pointing
  at a placeholder report that would never complete (#158).

  Now: one language's analysis runs to completion before the next starts, a
  language's report is replaced only by a complete one, and progress survives
  restarts -- a language refreshed within the last day is skipped, so a kill
  costs the language in flight rather than the night.

  Options (for tests): `:languages`, `:now`, `:fetch`, `:repo_size`, `:analyze`,
  `:force`.
  """
  def refresh_due(opts \\ []) do
    lock_ms = Keyword.get(opts, :lock_ms, @lock_ms)

    with_lock(lock_ms, fn token ->
      opts
      |> Keyword.get_lazy(:languages, fn ->
        Application.get_env(:lowendinsight_get, :languages)
      end)
      |> Enum.filter(&(Keyword.get(opts, :force, false) or due?(&1, Keyword.get(opts, :now))))
      |> Enum.map(fn language ->
        result = refresh(language, opts)
        extend_lock(token, lock_ms)
        {language, result}
      end)
    end)
  end

  @doc "Refreshes every language regardless of age. The manual trigger."
  def process_languages() do
    refresh_due(force: true)
  end

  @doc """
  Whether a language's last completed report is older than a day, or absent.
  """
  def due?(language, now \\ nil) do
    now = now || DateTime.utc_now()

    case completed_at(language) do
      nil -> true
      completed -> DateTime.diff(now, completed) >= @refresh_after_seconds
    end
  end

  @doc "When a language's current report was completed, or nil."
  def completed_at(language) do
    case Redix.command(:redix, ["GET", completed_key(language)]) do
      {:ok, iso} when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Analyses one language's trending repositories, synchronously, and points the
  page at the result only if it completed.
  """
  def refresh(language, opts \\ []) do
    fetch = Keyword.get(opts, :fetch, &fetch_trending_list/1)
    analyze = Keyword.get(opts, :analyze, &LowendinsightGet.Analysis.process/3)
    uuid = UUID.uuid1()

    Logger.info("Github Trending Analysis: {#{language}}")

    with {:ok, list} <- fetch.(language),
         [_ | _] = urls <- candidate_urls(list, Keyword.get(opts, :repo_size, &get_repo_size/1)),
         :ok <- run_analysis(analyze, uuid, urls),
         :ok <- ensure_complete(uuid) do
      {:ok, _} =
        Redix.pipeline(:redix, [
          ["SET", "gh_trending_#{language}_uuid", uuid],
          ["SET", completed_key(language), DateTime.utc_now() |> DateTime.to_iso8601()]
        ])

      Logger.info("Github Trending Analysis complete: {#{language}} #{length(urls)} repos")
      {:ok, uuid}
    else
      [] ->
        Logger.warning("Github Trending Analysis: no analysable repositories for #{language}")
        {:error, :no_repositories}

      {:error, reason} = error ->
        # The previous report stays: a failed refresh is never published.
        Logger.error("Github Trending Analysis failed for #{language}: #{inspect(reason)}")
        error
    end
  end

  defp run_analysis(analyze, uuid, urls) do
    analyze.(uuid, urls, DateTime.utc_now())
    :ok
  rescue
    e -> {:error, {:analysis_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:analysis_exited, kind, reason}}
  end

  defp ensure_complete(uuid) do
    with {:ok, json} <- LowendinsightGet.Datastore.get_job(uuid),
         {:ok, %{"state" => "complete"}} <- Poison.decode(json) do
      :ok
    else
      {:ok, %{"state" => state}} -> {:error, {:incomplete, state}}
      other -> {:error, {:no_report, other}}
    end
  end

  # Too-large repositories are dropped. They were marked "-skip_too_big" and
  # sent for analysis anyway, which cost a clone attempt of a URL that does not
  # exist and put an error row in the report.
  defp candidate_urls(list, repo_size) do
    check_repo? = check_repo_size?()
    num_of_repos = Application.get_env(:lowendinsight_get, :num_of_repos) || 5

    list
    |> filter_to_urls()
    |> Enum.map(fn url -> if check_repo?, do: repo_size.(url), else: {0, url} end)
    |> Enum.flat_map(fn
      {size, url} when is_binary(url) ->
        if keep_repo?(size, check_repo?), do: [url], else: []

      _ ->
        []
    end)
    |> Enum.take(num_of_repos)
  end

  defp with_lock(lock_ms, fun) do
    token = UUID.uuid4()

    case Redix.command(:redix, ["SET", @lock_key, token, "NX", "PX", lock_ms]) do
      {:ok, "OK"} ->
        try do
          fun.(token)
        after
          case Redix.command(:redix, ["GET", @lock_key]) do
            {:ok, ^token} -> Redix.command(:redix, ["DEL", @lock_key])
            _ -> :ok
          end
        end

      {:ok, nil} ->
        Logger.info("Github Trending Analysis already running; skipping this run")
        {:error, :already_running}

      {:error, reason} ->
        {:error, {:lock_unavailable, reason}}
    end
  end

  # Only extends a lock this run still holds. Get-then-set races an expiry by a
  # few microseconds; the cost of losing that race is one overlapping language,
  # not a wedged job.
  defp extend_lock(token, lock_ms) do
    case Redix.command(:redix, ["GET", @lock_key]) do
      {:ok, ^token} -> Redix.command(:redix, ["PEXPIRE", @lock_key, lock_ms])
      _ -> :ok
    end
  end

  defp completed_key(language), do: "gh_trending_#{language}_completed_at"

  # Monitoring needs to tell "disabled on purpose" from "enabled and failing":
  # a freshness alert that fires every 15 minutes for a job that is switched off
  # is a permanently red monitor, and a red monitor hides the next real failure.
  defp job_active? do
    case LowendinsightGet.Scheduler.find_job(:github_trending) do
      %{state: :active} -> true
      _ -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  @doc """
  `/metrics` lines: whether each language has a completed report, and its age.

  Registered through `:metrics_collectors` so the library stays free of Redis.
  Monitoring fails on a language with no completed report or one older than
  two days -- the state that went unnoticed while the pages showed nothing.
  """
  def metrics(now \\ nil) do
    now = now || DateTime.utc_now()
    languages = Application.get_env(:lowendinsight_get, :languages) || []

    rows = Enum.map(languages, fn l -> {l, completed_at(l)} end)

    [
      "# HELP lei_trending_job_active Whether the scheduled trending job is enabled",
      "# TYPE lei_trending_job_active gauge",
      "lei_trending_job_active #{if job_active?(), do: 1, else: 0}",
      "# HELP lei_trending_report_completed Whether a language has a completed trending report",
      "# TYPE lei_trending_report_completed gauge"
    ] ++
      Enum.map(rows, fn {l, c} ->
        ~s(lei_trending_report_completed{language="#{l}"} #{if c, do: 1, else: 0})
      end) ++
      [
        "# HELP lei_trending_report_age_seconds Age of each language's completed trending report",
        "# TYPE lei_trending_report_age_seconds gauge"
      ] ++
      for(
        {l, c} <- rows,
        c,
        do: ~s(lei_trending_report_age_seconds{language="#{l}"} #{DateTime.diff(now, c)})
      )
  end

  def get_current_gh_trending_report(language) do
    empty_report = fn id ->
      %{
        "metadata" => %{"times" => %{}},
        "report" => %{"uuid" => id, "repos" => []}
      }
    end

    case Redix.command(:redix, ["GET", "gh_trending_#{language}_uuid"]) do
      {:error, reason} ->
        Logger.error("Redis error fetching trending UUID for #{language}: #{inspect(reason)}")
        empty_report.(UUID.uuid1())

      {:ok, nil} ->
        empty_report.(UUID.uuid1())

      {:ok, uuid} ->
        case Redix.command(:redix, ["GET", uuid]) do
          {:ok, nil} ->
            Logger.warning("gh_trending report #{uuid} not found in Redis (may have expired)")
            empty_report.(uuid)

          {:ok, report_json} ->
            Poison.Parser.parse!(report_json, %{})

          {:error, reason} ->
            Logger.error("Redis error fetching trending report #{uuid}: #{inspect(reason)}")
            empty_report.(uuid)
        end
    end
  end

  defp get_token() do
    if Application.fetch_env(:lowendinsight_get, :gh_token) == :error,
      do: "",
      else: Application.fetch_env!(:lowendinsight_get, :gh_token)
  end

  defp fetch_gh_api_response(token, slug) do
    headers = [Authorization: "Bearer #{token}", Accept: "Application/json; Charset=utf-8"]
    HTTPoison.get("https://api.github.com/repos/" <> slug, headers)
  end

  # {size_in_kb | nil, url}. Never raises: one repository the API cannot
  # describe (rate limit, deleted, network) must not abort a language's refresh.
  def get_repo_size(url) do
    with {:ok, slug} <- Helpers.get_slug(url),
         {:ok, %HTTPoison.Response{status_code: 200, body: body}} <-
           fetch_gh_api_response(get_token(), slug),
         {:ok, %{"size" => size}} <- Poison.decode(body) do
      {size, url}
    else
      _ -> {nil, url}
    end
  end

  # Clone time and disk, now that analysis memory no longer scales with history
  # (#162). It was 1,000,000 KB -- 1 GB, on a machine with 459 MB of memory --
  # and let plausible/analytics (671 MB) and firezone (411 MB) through.
  @default_max_repo_size_kb 250_000

  @doc "Whether a repository of this size (GitHub KB) is analysed."
  def keep_repo?(_size, false), do: true

  def keep_repo?(size, true) when is_integer(size),
    do:
      size <
        Application.get_env(
          :lowendinsight_get,
          :trending_max_repo_size_kb,
          @default_max_repo_size_kb
        )

  # Size unknown (API error, private, deleted): not analysed.
  def keep_repo?(_size, true), do: false

  def get_wait_time() do
    if Application.fetch_env(:lowendinsight_get, :wait_time) == :error,
      do: 1_800_000,
      else: Application.fetch_env!(:lowendinsight_get, :wait_time)
  end

  def check_repo_size?() do
    if Application.fetch_env(:lowendinsight_get, :check_repo_size?) == :error,
      do: false,
      else: Application.fetch_env!(:lowendinsight_get, :check_repo_size?)
  end

  defp filter_to_urls(list) do
    for repo <- list, do: repo["url"]
  end

  @doc false
  def fetch_trending_list(language) do
    case fetch_from_ossinsight(language) do
      {:ok, list} ->
        Logger.info("Fetched #{length(list)} trending repos from OSS Insight for #{language}")
        {:ok, list}

      {:error, reason} ->
        Logger.warning(
          "OSS Insight failed for #{language}: #{inspect(reason)}, falling back to GitHub Search"
        )

        fetch_from_github_search(language)
    end
  end

  @doc """
  Interprets an OSS Insight trends response.

  Since 2026-03-01 OSS Insight has answered with no rows and a `data_quality`
  block saying the ranking cannot be computed -- its capture of GitHub events
  fell to about 0.3% of baseline. That was logged as "no repos returned" for
  six months, with the GitHub Search fallback quietly doing all the work. The
  stated reason is surfaced now, so the log says what is true.
  """
  def parse_ossinsight(body) do
    case Poison.decode(body) do
      {:ok, %{"data_quality" => %{"status" => "unavailable"} = quality}} ->
        {:error,
         {:ossinsight_unavailable,
          "since #{quality["unavailable_since"] || "unknown"}: #{quality["reason"] || "no reason given"}"}}

      {:ok, %{"data" => %{"rows" => rows}}} when is_list(rows) ->
        repos =
          rows
          |> Enum.filter(fn row -> is_binary(row["repo_name"]) end)
          |> Enum.map(fn row -> %{"url" => "https://github.com/" <> row["repo_name"]} end)

        if repos == [], do: {:error, "no repos returned"}, else: {:ok, repos}

      {:ok, _other} ->
        {:error, "unexpected OSS Insight response structure"}

      {:error, err} ->
        {:error, "JSON parse error: #{inspect(err)}"}
    end
  end

  @doc false
  def fetch_from_ossinsight(language) do
    display_lang = capitalize_language(language)

    url =
      @ossinsight_base <>
        "?" <>
        URI.encode_query(%{"language" => display_lang, "period" => "past_week"})

    Logger.info("Fetching trending from OSS Insight: #{url}")

    case HTTPoison.get(url, [], recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse_ossinsight(body)

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "OSS Insight HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  A GitHub Search query that approximates "trending" for a language.

  The previous query -- pushed in the last week, sorted by stars -- returned the
  most-starred repositories of all time that happened to have a recent commit:
  the largest, oldest, longest-history projects in each language, which is
  neither trending nor cheap to analyse (#158). GitHub Search cannot rank by
  stars gained recently, so the closest honest proxy is repositories *created*
  recently, ranked by the stars they already have: projects that are rising.

  90 days and 10 stars, checked 2026-09-14: 30 days and 20 stars left small
  ecosystems nearly empty (elixir 2 results, haskell 0), while 90/10 gives
  elixir 40 and haskell 8 and still puts strong new projects first for rust
  and dart, because results are ranked by stars.
  """
  def github_search_query(language, today) do
    since = today |> Date.add(-90) |> Date.to_iso8601()
    "language:#{language} created:>#{since} stars:>=10 fork:false archived:false"
  end

  @doc false
  def fetch_from_github_search(language) do
    token = get_token()
    query = github_search_query(language, Date.utc_today())

    url =
      @github_search_base <>
        "?" <>
        URI.encode_query(%{
          "q" => query,
          "sort" => "stars",
          "order" => "desc",
          "per_page" => "30"
        })

    headers =
      if token != "" do
        [Authorization: "Bearer #{token}", Accept: "application/vnd.github+json"]
      else
        [Accept: "application/vnd.github+json"]
      end

    Logger.info("Fetching trending from GitHub Search: #{url}")

    case HTTPoison.get(url, headers, recv_timeout: 30_000) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case Poison.decode(body) do
          {:ok, %{"items" => items}} when is_list(items) ->
            repos =
              items
              |> Enum.filter(fn item -> is_binary(item["html_url"]) end)
              |> Enum.map(fn item -> %{"url" => item["html_url"]} end)

            {:ok, repos}

          {:ok, _other} ->
            {:error, "unexpected GitHub Search response structure"}

          {:error, err} ->
            {:error, "JSON parse error: #{inspect(err)}"}
        end

      {:ok, %HTTPoison.Response{status_code: status, body: body}} ->
        {:error, "GitHub Search HTTP #{status}: #{String.slice(body, 0, 200)}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc false
  def capitalize_language(lang) do
    case String.downcase(lang) do
      "c++" -> "C++"
      "c#" -> "C#"
      "objective-c" -> "Objective-C"
      "javascript" -> "JavaScript"
      "typescript" -> "TypeScript"
      other -> String.capitalize(other)
    end
  end
end
