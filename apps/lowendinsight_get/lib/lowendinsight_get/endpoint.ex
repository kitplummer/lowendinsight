# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.Endpoint do
  use Plug.Router

  # use Plug.Debugger

  use Plug.ErrorHandler

  # alias Plug.{Adapters.Cowboy}

  require Logger
  alias Plug.{Adapters.Cowboy}
  plug(LowendinsightGet.Auth)
  plug(Plug.Logger, log: :debug)
  plug(Plug.Static, from: "priv/static/images", at: "/images")
  plug(Plug.Static, from: "priv/static/js", at: "/js")
  plug(Plug.Static, from: "priv/static/css", at: "/css")

  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["application/json", "text/*"],
    json_decoder: Poison
  )

  plug(:match)
  plug(:dispatch)

  @content_type "application/json"

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(_opts) do
    with {:ok, [port: port] = config} <- config() do
      Logger.info("Starting server at http://localhost:#{port}/")
      # Increase idle_timeout to support blocking analysis with longer cache_timeouts
      # Default Cowboy idle_timeout is 60s, but blocking analysis may take 2+ minutes
      Cowboy.http(__MODULE__, [], config ++ [protocol_options: [idle_timeout: 180_000]])
    end
  end

  get "/" do
    render(conn, "analyze.html", report: "")
  end

  get "/doc" do
    {:ok, html} = File.read("#{:code.priv_dir(:lowendinsight_get)}/static/index.html")

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  get "/openapi.json" do
    {:ok, spec} = File.read("#{:code.priv_dir(:lowendinsight_get)}/static/openapi.json")

    conn
    |> put_resp_content_type(@content_type)
    |> put_resp_header("access-control-allow-origin", "*")
    |> send_resp(200, spec)
  end

  get "/gh_trending" do
    languages = Application.get_env(:lowendinsight_get, :languages)
    render(conn, "index.html", languages: languages)
  end

  get "/gh_trending/:language" do
    languages = Application.get_env(:lowendinsight_get, :languages)

    render(conn, "language.html",
      report: LowendinsightGet.GithubTrending.get_current_gh_trending_report(language),
      language: language,
      languages: languages
    )
  end

  get "/url=:url" do
    url = URI.decode(url)

    case LowendinsightGet.Analysis.analyze(url, "lei-get", %{types: false}) do
      {:ok, report, _cache_status} ->
        {:ok, data} = Map.fetch(report, :data)
        error_key? = Map.fetch(data, :error)

        case error_key? do
          :error ->
            render(conn, "analysis.html",
              report: Poison.encode!(report, as: %RepoReport{data: %Data{results: %Results{}}}),
              url: url
            )

          _ ->
            conn
            |> put_resp_content_type(@content_type)
            |> send_resp(401, Poison.encode!(%{:error => "Invalid url"}))
        end

      {:error, msg} ->
        Logger.error(msg)
        {:error, msg}
    end
  end

  get "/validate-url/url=:url" do
    url = URI.decode(url)

    {status, body} =
      case Helpers.validate_url(url) do
        :ok ->
          {200, Poison.encode!(%{:ok => "valid url"})}

        {:error, msg} ->
          {201, Poison.encode!(%{:error => msg})}
      end

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  @valid_cache_modes ["blocking", "async", "stale"]

  ## API Bits
  get "/v1/analyze/:uuid" do
    {status, body} = fetch_job(uuid)

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  get "/v1/job/:id" do
    {status, body} = fetch_job(id)

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  post "/v1/analyze" do
    start_time = DateTime.utc_now()
    uuid = UUID.uuid1()

    {status, body} =
      case conn.body_params do
        %{"urls" => urls} ->
          cache_mode = Map.get(conn.body_params, "cache_mode", "blocking")

          cache_timeout =
            Map.get(
              conn.body_params,
              "cache_timeout",
              Application.get_env(:lowendinsight_get, :default_cache_timeout, 30_000)
            )

          if cache_mode in @valid_cache_modes do
            opts = %{cache_mode: cache_mode, cache_timeout: cache_timeout}

            case LowendinsightGet.Analysis.process_urls(urls, uuid, start_time, opts) do
              {:ok, result} ->
                {200, result}

              {:timeout, timed_out_uuid} ->
                {202,
                 Poison.encode!(%{
                   state: "incomplete",
                   uuid: timed_out_uuid,
                   error: "analysis did not complete within #{cache_timeout}ms timeout"
                 })}

              {:error, error} ->
                {422, Poison.encode!(%{:error => error})}
            end
          else
            {422,
             Poison.encode!(%{
               error:
                 "invalid cache_mode: '#{cache_mode}'. Must be one of: #{Enum.join(@valid_cache_modes, ", ")}"
             })}
          end

        _ ->
          {422, process()}
      end

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  post "/v1/analyze/sbom" do
    start_time = DateTime.utc_now()
    uuid = UUID.uuid1()

    {status, body} =
      case conn.body_params do
        %{"sbom" => sbom} ->
          cache_mode = Map.get(conn.body_params, "cache_mode", "async")

          cache_timeout =
            Map.get(
              conn.body_params,
              "cache_timeout",
              Application.get_env(:lowendinsight_get, :sbom_timeout, 60_000)
            )

          if cache_mode in @valid_cache_modes do
            case LowendinsightGet.SbomParser.parse(sbom) do
              {:ok, urls} when length(urls) > 0 ->
                opts = %{cache_mode: cache_mode, cache_timeout: cache_timeout}

                case LowendinsightGet.Analysis.process_urls(urls, uuid, start_time, opts) do
                  {:ok, result} ->
                    # Enhance result with SBOM metadata
                    enhanced = add_sbom_metadata(result, length(urls))
                    {200, enhanced}

                  {:timeout, timed_out_uuid} ->
                    {202,
                     Poison.encode!(%{
                       state: "incomplete",
                       uuid: timed_out_uuid,
                       sbom_urls_found: length(urls),
                       error: "SBOM analysis did not complete within #{cache_timeout}ms timeout"
                     })}

                  {:error, error} ->
                    {422, Poison.encode!(%{error: error})}
                end

              {:ok, []} ->
                {422, Poison.encode!(%{error: "no git URLs found in SBOM"})}

              {:error, reason} ->
                {422, Poison.encode!(%{error: "SBOM parse error: #{reason}"})}
            end
          else
            {422,
             Poison.encode!(%{
               error:
                 "invalid cache_mode: '#{cache_mode}'. Must be one of: #{Enum.join(@valid_cache_modes, ", ")}"
             })}
          end

        _ ->
          {422,
           Poison.encode!(%{
             error: "POST body must contain 'sbom' field with CycloneDX or SPDX JSON"
           })}
      end

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  ## Cache Management Endpoints (Phase 3: Distributable Cache)

  @doc """
  GET /v1/cache/export - Export entire cache for air-gapped deployment.
  Returns JSON with all cached analysis reports.
  """
  get "/v1/cache/export" do
    {:ok, entries, stats} = LowendinsightGet.Datastore.export_cache()

    body =
      Poison.encode!(%{
        "entries" => entries,
        "stats" => stats
      })

    conn
    |> put_resp_content_type(@content_type)
    |> put_resp_header("content-disposition", "attachment; filename=\"lei-cache-export.json\"")
    |> send_resp(200, body)
  end

  @doc """
  POST /v1/cache/import - Import pre-warmed cache for air-gapped deployment.
  Accepts JSON with "entries" array from export endpoint.
  Options: overwrite (bool), ttl (seconds)
  """
  post "/v1/cache/import" do
    {status, body} =
      case conn.body_params do
        %{"entries" => entries} when is_list(entries) ->
          overwrite = Map.get(conn.body_params, "overwrite", false)
          ttl = Map.get(conn.body_params, "ttl", nil)

          opts = if ttl, do: [overwrite: overwrite, ttl: ttl], else: [overwrite: overwrite]

          case LowendinsightGet.Datastore.import_cache(entries, opts) do
            {:ok, stats} ->
              {200, Poison.encode!(%{success: true, stats: stats})}
          end

        _ ->
          {422,
           Poison.encode!(%{
             error: "POST body must contain 'entries' array from cache export"
           })}
      end

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, body)
  end

  @doc """
  GET /v1/cache/stats - Get cache statistics.
  """
  get "/v1/cache/stats" do
    stats = LowendinsightGet.Datastore.cache_stats()

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(200, Poison.encode!(stats))
  end

  post "/v1/gh_trending/process" do
    Task.start_link(fn -> LowendinsightGet.GithubTrending.process_languages() end)

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(200, "Processing languages...")
  end

  match _ do
    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(404, Poison.encode!(%{:error => "UUID not provided or found."}))
  end

  defp fetch_job(uuid) do
    try do
      case LowendinsightGet.Datastore.get_job(uuid) do
        {:ok, job} ->
          job_obj = Poison.decode!(job)

          case job_obj["state"] do
            "complete" ->
              {200, job}

            "incomplete" ->
              Logger.debug("refreshing report")
              refreshed_job = LowendinsightGet.Analysis.refresh_job(job_obj)
              {200, Poison.encode!(refreshed_job)}

            state ->
              Logger.debug("job state: #{inspect(state)}, treating as incomplete")
              refreshed_job = LowendinsightGet.Analysis.refresh_job(job_obj)
              {200, Poison.encode!(refreshed_job)}
          end

        {:error, _job} ->
          {404, Poison.encode!(%{:error => "invalid UUID provided, no job found."})}
      end
    rescue
      e ->
        Logger.error("Error fetching job #{uuid}: #{inspect(e)}")

        {500,
         Poison.encode!(%{error: "Internal error fetching job", details: Exception.message(e)})}
    end
  end

  defp process do
    Poison.encode!(%{
      error:
        "this is a POSTful service, JSON body with valid git url param required and content-type set to application/json.  e.g. {\"urls\": [\"https://gitrepo/org/repo\", \"https://gitrepo/org/repo1\"]"
    })
  end

  defp add_sbom_metadata(result, url_count) when is_binary(result) do
    case Poison.decode(result) do
      {:ok, decoded} ->
        enhanced =
          Map.merge(decoded, %{
            "sbom_analysis" => true,
            "sbom_urls_found" => url_count
          })

        Poison.encode!(enhanced)

      {:error, _} ->
        result
    end
  end

  # defp config, do: Application.fetch_env(:lowendinsight_get, __MODULE__)

  defp render(%{status: status} = conn, template, assigns) do
    template_dir = Path.join(:code.priv_dir(:lowendinsight_get), "templates")

    body =
      template_dir
      |> Path.join(template)
      |> String.replace_suffix(".html", ".html.eex")
      |> EEx.eval_file(assigns)

    send_resp(conn, status || 200, body)
  end

  def handle_errors(conn, _) do
    send_resp(conn, conn.status, process())
  end

  defp config, do: Application.fetch_env(:lowendinsight_get, __MODULE__)
end
