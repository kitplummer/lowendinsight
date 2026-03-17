# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.GithubTrending do
  require Logger
  require HTTPoison.Retry

  @type language() :: String.t()

  @ossinsight_base "https://api.ossinsight.io/v1/trends/repos/"
  @github_search_base "https://api.github.com/search/repositories"

  def process_languages() do
    Application.get_env(:lowendinsight_get, :languages)
    |> Enum.each(fn language -> LowendinsightGet.GithubTrending.analyze(language) end)
  end

  @spec analyze(any) :: {:error, any} | {:ok, <<_::64, _::_*8>>}
  def analyze(language) do
    Logger.info("Github Trending Analysis: {#{language}}")
    uuid = UUID.uuid1()
    check_repo? = check_repo_size?()
    num_of_repos = Application.fetch_env!(:lowendinsight_get, :num_of_repos) || 5

    case fetch_trending_list(language) do
      {:error, reason} ->
        {:error, reason}

      {:ok, list} ->
        urls =
          filter_to_urls(list)
          |> Enum.map(fn url -> get_repo_size(url) end)
          |> Enum.map(fn {repo_size, url} ->
            filter_out_large_repos({repo_size, url}, check_repo?)
          end)
          |> Enum.take(num_of_repos)

        Logger.debug("URLS: #{inspect(urls)}")

        LowendinsightGet.Analysis.process_urls(
          urls,
          uuid,
          DateTime.utc_now()
        )

        # Write the UUID into the gh_trending entry in Redis
        Redix.command(:redix, ["SET", "gh_trending_#{language}_uuid", uuid])
        {:ok, "successfully started analyzing trending repos for job id:#{uuid}"}
    end
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

  def get_repo_size(url) do
    case Helpers.get_slug(url) do
      {:ok, slug} ->
        {:ok, response} = fetch_gh_api_response(get_token(), slug)
        json = Poison.Parser.parse!(response.body, %{})
        {json["size"], url}

      {:error, msg} ->
        {:error, msg}
    end
  end

  def filter_out_large_repos({repo_size, url}, check_repo?)
      when repo_size < 1_000_000 or not check_repo? do
    url
  end

  def filter_out_large_repos({_repo_size, url}, check_repo?) when check_repo? do
    url <> "-skip_too_big"
  end

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
        case Poison.decode(body) do
          {:ok, %{"data" => %{"rows" => rows}}} when is_list(rows) ->
            repos =
              rows
              |> Enum.filter(fn row -> is_binary(row["repo_name"]) end)
              |> Enum.map(fn row ->
                %{"url" => "https://github.com/" <> row["repo_name"]}
              end)

            if repos == [],
              do: {:error, "no repos returned"},
              else: {:ok, repos}

          {:ok, _other} ->
            {:error, "unexpected OSS Insight response structure"}

          {:error, err} ->
            {:error, "JSON parse error: #{inspect(err)}"}
        end

      {:ok, %HTTPoison.Response{status_code: status}} ->
        {:error, "OSS Insight HTTP #{status}"}

      {:error, %HTTPoison.Error{reason: reason}} ->
        {:error, reason}
    end
  end

  @doc false
  def fetch_from_github_search(language) do
    token = get_token()
    week_ago = Date.utc_today() |> Date.add(-7) |> Date.to_iso8601()

    query = "language:#{language} pushed:>#{week_ago} stars:>10"

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
