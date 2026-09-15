# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.Endpoint do
  use Plug.Router

  # use Plug.Debugger

  use Plug.ErrorHandler

  # alias Plug.{Adapters.Cowboy}

  require Logger
  alias Plug.Cowboy
  # Paths forwarded to Lei.Web.Router. Anything not listed here falls through
  # to this endpoint's own routes and 404s, so a route added to Lei.Web.Router
  # is unreachable in production until its prefix appears here.
  @auth_paths ~w(/signup /login /dashboard /keys /logout /static /recover /webhooks
                 /v1/analyze/batch /v1/usage /v1/credits /v1/health /v1/orgs
                 /healthz /readyz /metrics)

  # First: every path check below must see the path the router matches.
  plug(Lei.Plugs.CanonicalPath)
  plug(LowendinsightGet.Auth)
  plug(LowendinsightGet.Plugs.RateLimiter)
  plug(Plug.Logger, log: :debug)
  plug(Plug.Static, from: {:lowendinsight_get, "priv/static/images"}, at: "/images")
  plug(Plug.Static, from: {:lowendinsight_get, "priv/static/js"}, at: "/js")
  plug(Plug.Static, from: {:lowendinsight_get, "priv/static/css"}, at: "/css")

  # Browsers request /favicon.ico from the root whether or not a link tag says
  # to, so the root path has to work on its own. `only` keeps this from serving
  # the rest of priv/static from /.
  plug(Plug.Static,
    from: {:lowendinsight_get, "priv/static/images"},
    at: "/",
    only: ~w(favicon.ico)
  )

  # RawBodyReader stashes the unparsed body in conn.private[:raw_body]. This is
  # the first Plug.Parsers in the pipeline, so it has to be the one to capture
  # it -- the ACP HMAC check and the Stripe webhook signature check both read
  # that key, and the parsers declared on the sub-routers are a no-op once the
  # body has already been fetched here.
  plug(Plug.Parsers,
    parsers: [:json, :urlencoded],
    pass: ["application/json", "text/*"],
    json_decoder: Poison,
    body_reader: {Lei.Acp.RawBodyReader, :read_body, []}
  )

  plug(:maybe_route_auth)
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
    with {:ok, config} <- config() do
      port = Keyword.get(config, :port, 4444)
      Logger.info("Starting server at http://localhost:#{port}/")
      # Increase idle_timeout to support blocking analysis with longer cache_timeouts
      # Default Cowboy idle_timeout is 60s, but blocking analysis may take 2+ minutes
      Cowboy.http(__MODULE__, [], config ++ [protocol_options: [idle_timeout: 180_000]])
    end
  end

  get "/" do
    render(conn, "analyze.html", report: "", guide: LowendinsightGet.AgentGuide.facts())
  end

  # The homepage's guide for agents that read markdown rather than HTML. Built
  # from the same facts, so the two cannot disagree about a price or a rail.
  get "/llms.txt" do
    template = Path.join([:code.priv_dir(:lowendinsight_get), "templates", "llms.txt.eex"])
    body = EEx.eval_file(template, guide: LowendinsightGet.AgentGuide.facts())

    conn
    |> put_resp_content_type("text/markdown")
    |> send_resp(200, body)
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

    # Before the allowance and before any work: this route cloned whatever it
    # was given, including file:// paths and private addresses.
    with :ok <- LowendinsightGet.RemoteUrl.validate(url),
         :ok <- try_it_allowance(conn, url) do
      try_it(conn, url)
    else
      {:limited, retry_after} -> try_it_limited(conn, retry_after)
      {:error, reason} -> send_json(conn, 400, %{error: "invalid url", reason: reason})
    end
  end

  # The Try It form is free for a person trying the product, and was free for
  # anything: an agent that reads HTML had a full analysis path around the 402
  # (#152). A cached report costs nothing to serve and stays unlimited; a fresh
  # analysis is limited per IP, checked before any work starts.
  defp try_it_allowance(conn, url) do
    if LowendinsightGet.Datastore.in_cache?(url) do
      :ok
    else
      ip = Lei.Payments.RateLimit.client_ip(conn)

      case Lei.RateLimiter.check("try_it:#{ip}", "try_it") do
        {:ok, _remaining} -> :ok
        {:error, :rate_limited, retry_after_ms} -> {:limited, max(div(retry_after_ms, 1000), 1)}
      end
    end
  end

  # The report page shows the whole report. Analysis.analyze/3 decodes a cache
  # hit into the RepoReport/Data/Results structs, which keep only the original
  # fields -- no header, git, files, size or agentic results -- so a cached
  # repository, which every trending "view" is, rendered mostly as blanks. The
  # full JSON is in the cache once analyze/3 has returned; the struct is only
  # the fallback if it cannot be read.
  defp full_report(url, report) do
    case LowendinsightGet.Datastore.get_from_cache_any_age(url) do
      {:ok, json, _} when is_binary(json) -> json
      _ -> Poison.encode!(report)
    end
  end

  defp try_it_limited(conn, retry_after) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after))
    |> send_json(429, %{
      error: "try_it_limit",
      message:
        "The Try It form's allowance of fresh analyses for your address is used up. " <>
          "Analyze through the API instead: POST /v1/analyze, paying per use with no account, " <>
          "or with a free key from /signup.",
      api: "/v1/analyze",
      guide: "/llms.txt",
      signup: "/signup",
      retry_after_seconds: retry_after
    })
  end

  defp try_it(conn, url) do
    case LowendinsightGet.Analysis.analyze(url, "lei-get", %{types: false}) do
      {:ok, report, _cache_status} ->
        {:ok, data} = Map.fetch(report, :data)
        error_key? = Map.fetch(data, :error)

        case error_key? do
          :error ->
            render(conn, "analysis.html", report: full_report(url, report), url: url)

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
      case LowendinsightGet.RemoteUrl.validate(url) do
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
    # Random, not time-based: the job id is the credential for reading the job
    # (decided 2026-09-15), so it must not be guessable.
    uuid = UUID.uuid4()

    # Payment first, so an agent refused with a 402 is served when it retries
    # this same request with a credential. Then admission: API key, payment, or
    # an operator token -- and anything else is asked to pay. This route had no
    # payment path at all, and answered a wallet org out of credits with a 500
    # from an unmatched case clause (#147).
    conn = Lei.Payments.Gate.settle(conn)

    # Refused before admission, because admission charges: a request that
    # cannot be analysed must not be billed (decided 2026-09-15).
    with :ok <- analyzable(conn.body_params),
         split = cache_split(conn.body_params["urls"]),
         {:ok, conn, billing} <- Lei.Payments.Gate.admit(conn, admission(split)) do
      {status, body} = analyze_urls(conn, billing, uuid, start_time)

      conn
      |> put_resp_content_type(@content_type)
      |> send_resp(status, body)
    else
      {:halt, conn} -> conn
      {:invalid, body} -> send_json(conn, 422, body)
    end
  end

  defp analyzable(%{"urls" => urls} = params) when is_list(urls) do
    cache_mode = Map.get(params, "cache_mode", "blocking")

    cond do
      cache_mode not in @valid_cache_modes ->
        {:invalid,
         %{
           error:
             "invalid cache_mode: '#{cache_mode}'. Must be one of: #{Enum.join(@valid_cache_modes, ", ")}"
         }}

      true ->
        urls_analyzable(urls)
    end
  end

  defp analyzable(_params), do: {:invalid, %{error: "POST body must contain a 'urls' list"}}

  # The same body process_urls/4 answers with, so moving the check ahead of
  # admission does not change the API's response.
  defp urls_analyzable(urls) do
    if :ok == Helpers.validate_urls(urls) and
         :ok == LowendinsightGet.RemoteUrl.validate_all(urls),
       do: :ok,
       else: {:invalid, %{error: "invalid URLs list"}}
  end

  defp analyze_urls(conn, billing, uuid, start_time) do
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
              log_analyze_request(conn, billing, urls, result)
              {200, enrich_analyze_response(conn, result)}

            # Accepted and still running. Charged at admission; the report is
            # collected later from GET /v1/analyze/{uuid}, which bills nothing.
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
  end

  post "/v1/analyze/sbom" do
    start_time = DateTime.utc_now()
    # Random, not time-based: the job id is the credential for reading the job
    # (decided 2026-09-15), so it must not be guessable.
    uuid = UUID.uuid4()

    # Paid like the other analyze routes. It checked no quota and recorded no
    # usage, so any key -- a wallet org's with no credits included -- could have
    # every repository an SBOM names analysed for nothing (#152). The SBOM is
    # parsed before admission because the repositories it names are the price.
    conn = Lei.Payments.Gate.settle(conn)

    with {:ok, urls, cache_mode, cache_timeout} <- sbom_request(conn.body_params),
         :ok <- urls_analyzable(urls),
         split = cache_split(urls),
         {:ok, conn, _billing} <- Lei.Payments.Gate.admit(conn, admission(split)) do
      opts = %{cache_mode: cache_mode, cache_timeout: cache_timeout}

      # Charged at admission, so nothing is recorded here.
      case LowendinsightGet.Analysis.process_urls(urls, uuid, start_time, opts) do
        {:ok, result} ->
          conn
          |> put_resp_content_type(@content_type)
          |> send_resp(200, add_sbom_metadata(result, length(urls)))

        {:timeout, timed_out_uuid} ->
          send_json(conn, 202, %{
            state: "incomplete",
            uuid: timed_out_uuid,
            sbom_urls_found: length(urls),
            error: "SBOM analysis did not complete within #{cache_timeout}ms timeout"
          })

        {:error, error} ->
          send_json(conn, 422, %{error: error})
      end
    else
      {:error, message} -> send_json(conn, 422, %{error: message})
      {:invalid, body} -> send_json(conn, 422, body)
      {:halt, conn} -> conn
    end
  end

  defp sbom_request(%{"sbom" => sbom} = params) do
    cache_mode = Map.get(params, "cache_mode", "async")

    cache_timeout =
      Map.get(
        params,
        "cache_timeout",
        Application.get_env(:lowendinsight_get, :sbom_timeout, 60_000)
      )

    cond do
      cache_mode not in @valid_cache_modes ->
        {:error,
         "invalid cache_mode: '#{cache_mode}'. Must be one of: #{Enum.join(@valid_cache_modes, ", ")}"}

      true ->
        case LowendinsightGet.SbomParser.parse(sbom) do
          {:ok, [_ | _] = urls} -> {:ok, urls, cache_mode, cache_timeout}
          {:ok, []} -> {:error, "no git URLs found in SBOM"}
          {:error, reason} -> {:error, "SBOM parse error: #{reason}"}
        end
    end
  end

  defp sbom_request(_params),
    do: {:error, "POST body must contain 'sbom' field with CycloneDX or SPDX JSON"}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(status, Poison.encode!(body))
  end

  # What a request will cost, decided before any work: a repository with a
  # cached report is a hit, anything else a miss. Billing from the response
  # instead recorded nothing for async, stale and timed-out requests, whose
  # responses carry no cache counts (#152).
  defp cache_split(urls) when is_list(urls) do
    urls = Enum.filter(urls, &is_binary/1)
    hits = Enum.count(urls, &LowendinsightGet.Datastore.in_cache?/1)
    {hits, length(urls) - hits}
  end

  defp cache_split(_), do: {0, 0}

  defp admission(split), do: [required_credits: credits_for(split), usage: split]

  defp credits_for({hits, misses}) do
    Lei.UsageTracker.calculate_cost(hits, misses)
    |> Decimal.mult(10)
    |> Decimal.round(0, :ceiling)
    |> Decimal.to_integer()
  end

  ## Cache Management Endpoints (Phase 3: Distributable Cache)

  # GET /v1/cache/export - Export entire cache for air-gapped deployment.
  # Returns JSON with all cached analysis reports.
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

  # POST /v1/cache/import - Import pre-warmed cache for air-gapped deployment.
  # Accepts JSON with "entries" array from export endpoint.
  # Options: overwrite (bool), ttl (seconds)
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

  # GET /v1/cache/stats - Get cache statistics.
  # POST /v1/cache/invalidate - drop a cached report so the next request for it
  # does the real analysis. Admin scope, enforced in LowendinsightGet.Auth.
  post "/v1/cache/invalidate" do
    case conn.body_params["url"] do
      url when is_binary(url) and url != "" ->
        case LowendinsightGet.Datastore.delete_from_cache(url) do
          {:ok, removed} ->
            conn
            |> put_resp_content_type(@content_type)
            |> send_resp(200, Poison.encode!(%{url: url, removed: removed}))

          {:error, reason} ->
            conn
            |> put_resp_content_type(@content_type)
            |> send_resp(503, Poison.encode!(%{error: "cache unavailable: #{inspect(reason)}"}))
        end

      _ ->
        conn
        |> put_resp_content_type(@content_type)
        |> send_resp(400, Poison.encode!(%{error: "missing required field: url"}))
    end
  end

  get "/v1/cache/stats" do
    stats = LowendinsightGet.Datastore.cache_stats()

    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(200, Poison.encode!(stats))
  end

  # GET /admin - Admin dashboard showing cache stats, usage monitoring, and active jobs.
  # Protected by LEI_ADMIN_TOKEN env var; pass token via ?token= query parameter.
  # Returns 401 if token is missing or invalid.
  get "/admin" do
    conn = fetch_query_params(conn)

    if admin_authorized?(conn) do
      cache_stats = LowendinsightGet.Datastore.cache_stats()
      cache_expiry = LowendinsightGet.Datastore.cache_expiry_info()
      recent_requests = LowendinsightGet.RequestLogger.get_recent(100)
      all_requests = LowendinsightGet.RequestLogger.get_all()

      hits = Enum.count(all_requests, &(&1.cache_status == :hit))
      misses = Enum.count(all_requests, &(&1.cache_status == :miss))
      total_tracked = length(all_requests)

      per_org =
        all_requests
        |> Enum.group_by(& &1.org_id)
        |> Enum.map(fn {org_id, reqs} ->
          org_hits = Enum.count(reqs, &(&1.cache_status == :hit))
          org_misses = Enum.count(reqs, &(&1.cache_status == :miss))
          %{org_id: org_id, total: length(reqs), hits: org_hits, misses: org_misses}
        end)
        |> Enum.sort_by(& &1.total, :desc)

      render(conn, "admin.html",
        cache_stats: cache_stats,
        cache_expiry: cache_expiry,
        recent_requests: recent_requests,
        hits: hits,
        misses: misses,
        total_tracked: total_tracked,
        per_org: per_org
      )
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(
        401,
        "<html><body><h1>401 Unauthorized</h1><p>Supply the admin token via an <code>Authorization: Bearer</code> header, or <code>?token=</code>.</p></body></html>"
      )
    end
  end

  # Fails closed: an unset LEI_ADMIN_TOKEN denies everyone rather than opening
  # the dashboard, which is the right default. But it also made /admin silently
  # unreachable for as long as the secret went unset, so log that case
  # distinctly -- "never configured" and "wrong token" should not look the same
  # to an operator, even though they must look the same to a caller.
  defp admin_authorized?(conn) do
    case System.get_env("LEI_ADMIN_TOKEN", "") do
      "" ->
        Logger.warning("/admin requested but LEI_ADMIN_TOKEN is not set; denying")
        false

      expected ->
        Plug.Crypto.secure_compare(admin_token_from_request(conn), expected)
    end
  end

  # Header first: a token in the query string lands in access logs, browser
  # history and Referer headers. The query parameter stays supported because it
  # is what makes the dashboard usable from a browser.
  defp admin_token_from_request(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> conn.query_params["token"] || ""
    end
  end

  # Operator only. This forces a refresh of every language -- the job that
  # exhausted production's memory (#158) -- and any API key could start it,
  # again the moment the last run released its lock (security review,
  # 2026-09-14). An operator token is signed with the deployment's own secret.
  post "/v1/gh_trending/process" do
    if conn.assigns[:auth_method] == :jwt do
      Task.start_link(fn -> LowendinsightGet.GithubTrending.process_languages() end)

      conn
      |> put_resp_content_type(@content_type)
      |> send_resp(200, "Processing languages...")
    else
      send_json(conn, 403, %{error: "operator credentials required"})
    end
  end

  match _ do
    conn
    |> put_resp_content_type(@content_type)
    |> send_resp(404, Poison.encode!(%{:error => "UUID not provided or found."}))
  end

  # Logged against the org the gate billed -- the key's, or the one a payment
  # on this request identified. Keyed on the API key alone, a paying agent's
  # first request was logged with no org, its URLs and all (#149).
  defp log_analyze_request(conn, {org_id, key_id, _tier}, urls, result) when is_binary(result) do
    org =
      case conn.assigns[:current_api_key] do
        %{org: %Lei.Org{id: ^org_id} = org} -> org
        _ -> org_id && Lei.Repo.get(Lei.Org, org_id)
      end

    cache_status =
      case Poison.decode(result) do
        {:ok, decoded} ->
          hits = get_in(decoded, ["metadata", "cache_status", "hits"]) || 0
          misses = get_in(decoded, ["metadata", "cache_status", "misses"]) || 0
          if hits > 0, do: :hit, else: if(misses > 0, do: :miss, else: nil)

        _ ->
          nil
      end

    LowendinsightGet.RequestLogger.log_request("/v1/analyze", org, key_id, urls, cache_status)
  end

  defp log_analyze_request(_conn, _billing, _urls, _result), do: :ok

  defp enrich_analyze_response(conn, result) when is_binary(result) do
    case conn.assigns[:current_api_key] do
      nil ->
        result

      api_key ->
        case Poison.decode(result) do
          {:ok, decoded} ->
            hits = get_in(decoded, ["metadata", "cache_status", "hits"]) || 0
            misses = get_in(decoded, ["metadata", "cache_status", "misses"]) || 0
            cost = Lei.UsageTracker.calculate_cost(hits, misses)

            enriched =
              Map.put(decoded, "billing", %{
                "cache_hits" => hits,
                "cache_misses" => misses,
                "cost_cents" => Decimal.to_float(cost),
                "tier" => api_key.org.tier
              })

            Poison.encode!(enriched)

          {:error, _} ->
            result
        end
    end
  end

  defp enrich_analyze_response(_conn, result), do: result

  @job_id ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  # A job is read by its id, which is the credential for it. Anything that is
  # not UUID-shaped is refused before Redis is asked: the id was used directly
  # as a key, so any value in the database could be read through this route.
  defp fetch_job(uuid) do
    if Regex.match?(@job_id, uuid), do: read_job(uuid), else: job_not_found()
  end

  defp job_not_found,
    do: {404, Poison.encode!(%{:error => "invalid UUID provided, no job found."})}

  defp read_job(uuid) do
    try do
      case LowendinsightGet.Datastore.get_job(uuid) do
        {:ok, job} ->
          job_obj = Poison.decode!(job)

          case job_obj["state"] do
            "complete" -> {200, job}
            _incomplete -> {200, refresh_incomplete(uuid, job, job_obj)}
          end

        {:error, _job} ->
          job_not_found()
      end
    rescue
      e ->
        # Logged in full, answered without detail: an exception's message can
        # carry internal state.
        Logger.error("Error fetching job #{uuid}: #{inspect(e)}")
        {500, Poison.encode!(%{error: "Internal error fetching job"})}
    end
  end

  # Refreshing an incomplete job can start analysis of its uncached URLs. That
  # used to happen on every poll, so a repository that keeps failing was
  # re-cloned on every request. Now at most once per job per window, under a
  # Redis lock; a poll inside the window gets the job as it stands. A running
  # analysis writes the finished job itself, so nothing waits on the refresh.
  @job_refresh_window_ms 300_000

  defp refresh_incomplete(uuid, job, job_obj) do
    case Redix.command(:redix, [
           "SET",
           "job_refresh:" <> uuid,
           "1",
           "NX",
           "PX",
           @job_refresh_window_ms
         ]) do
      {:ok, "OK"} ->
        refresher =
          Application.get_env(
            :lowendinsight_get,
            :job_refresher,
            &LowendinsightGet.Analysis.refresh_job/1
          )

        Poison.encode!(refresher.(job_obj))

      _ ->
        job
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
    version = Application.spec(:lowendinsight_get, :vsn) |> to_string()
    assigns = Keyword.put(assigns, :version, version)

    body =
      template_dir
      |> Path.join(template)
      |> String.replace_suffix(".html", ".html.eex")
      # Escapes every <%= %>. Report pages render repository data that the
      # repository's owner controls; with plain EEx it was written as markup.
      |> EEx.eval_file(assigns, engine: Lei.Web.HTMLEngine)

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status || 200, body)
  end

  def handle_errors(conn, _) do
    send_resp(conn, conn.status, process())
  end

  defp config, do: Application.fetch_env(:lowendinsight_get, __MODULE__)

  # Lei.Acp.Router matches on "/checkout", not "/acp/checkout", so the "/acp"
  # prefix has to be stripped before dispatching. Plug.forward/4 moves it from
  # path_info to script_name; calling the router directly leaves the prefix in
  # place and every request falls through to its catch-all 404.
  defp maybe_route_auth(%Plug.Conn{path_info: ["acp" | rest]} = conn, _opts) do
    conn
    |> Plug.forward(rest, Lei.Acp.Router, Lei.Acp.Router.init([]))
    |> halt()
  end

  # Lei.Web.Router declares its routes with the full path, so nothing is
  # stripped here.
  defp maybe_route_auth(%Plug.Conn{request_path: path} = conn, _opts) do
    if Enum.any?(@auth_paths, &String.starts_with?(path, &1)) do
      conn
      |> Lei.Web.Router.call(Lei.Web.Router.init([]))
      |> halt()
    else
      conn
    end
  end
end
