defmodule Lei.Analyze do
  require Logger

  @moduledoc """
  A list of repositories: validated, priced, run, and billed for what ran.

  `POST /v1/analyze` was the only caller, and all of this lived in its route.
  It moved here so a second entry point -- MCP's `analyze_repositories` --
  runs the same validation, the same price and the same refund of work that
  never reached the queue. Two copies of a billing path drift (#147); this is
  the move `Lei.Batch` made for the batch route.

  Admission sits between `price/1` and `run/4` and stays with the caller: who
  is asked to pay, and how they are told, differs by protocol.

  `/v1/analyze/sbom` shares the URL check, the price and the refund, but runs
  its own request: its response and its defaults differ.
  """

  @valid_cache_modes ["blocking", "async", "stale"]

  @doc """
  `{:ok, request}` with `:urls`, `:cache_mode` and `:cache_timeout`, or
  `{:invalid, body}` for a request that must be refused before admission,
  because admission charges (decided 2026-09-15).
  """
  def validate(%{"urls" => urls} = params) when is_list(urls) do
    cache_mode = Map.get(params, "cache_mode", "blocking")

    cache_timeout =
      Map.get(
        params,
        "cache_timeout",
        Application.get_env(:lei_service, :default_cache_timeout, 30_000)
      )

    with :ok <- check_cache_mode(cache_mode),
         :ok <- check_urls(urls) do
      {:ok, %{urls: urls, cache_mode: cache_mode, cache_timeout: cache_timeout}}
    else
      {:error, message} -> {:invalid, %{error: message}}
      {:invalid, body} -> {:invalid, body}
    end
  end

  def validate(_params), do: {:invalid, %{error: "POST body must contain a 'urls' list"}}

  @doc "`:ok`, or `{:error, message}` naming the modes there are."
  def check_cache_mode(cache_mode) when cache_mode in @valid_cache_modes, do: :ok

  def check_cache_mode(cache_mode) do
    {:error,
     "invalid cache_mode: '#{cache_mode}'. Must be one of: #{Enum.join(@valid_cache_modes, ", ")}"}
  end

  @doc """
  `:ok`, or `{:invalid, body}` -- the body `LeiService.Analysis.process_urls/4`
  answers with, so checking ahead of admission does not change the response.
  """
  # The cap is checked here rather than per route, because this is what both
  # /v1/analyze and /v1/analyze/sbom already call. A limit applied at two of
  # three entry points is not a limit (ADR-008).
  def check_urls(urls) do
    with :ok <- Lei.RequestScope.check(urls),
         true <- :ok == Helpers.validate_urls(urls),
         true <- :ok == LeiService.RemoteUrl.validate_all(urls) do
      :ok
    else
      {:error, %{} = over_cap} -> {:invalid, over_cap}
      _ -> {:invalid, %{error: "invalid URLs list"}}
    end
  end

  @doc """
  `{{cache_hits, cache_misses}, admission}`: the split, and the options
  `Lei.Payments.Gate` admits it with.
  """
  # What a request will cost, decided before any work: a repository with a
  # cached report is a hit, anything else a miss. Billing from the response
  # instead recorded nothing for async, stale and timed-out requests, whose
  # responses carry no cache counts (#152).
  def price(urls) do
    split = cache_split(urls)
    {split, [required_credits: credits_for(split), usage: split]}
  end

  @doc """
  Runs an admitted request. `billing` is admission's `{org_id, api_key_id,
  tier}`, which was charged for `split`; `context` carries the job's `:uuid`,
  the request's `:start_time`, the `:route` it came in on and the caller's
  `:api_key`, or nil.

  `{:ok, body}` with the report as JSON, `{:incomplete, body}` for work
  accepted and still running, `{:error, error}`, or `{:not_queued, body}`
  when the work never reached the queue and the charge was given back.
  """
  def run(request, billing, split, context) do
    # The org travels with the work so the worker can credit back an
    # analysis that determines nothing: admission charged for it before
    # the work ran, and the outcome is only known later (#258).
    opts = %{
      cache_mode: request.cache_mode,
      cache_timeout: request.cache_timeout,
      org_id: billing_org(billing)
    }

    try do
      case LeiService.Analysis.process_urls(
             request.urls,
             context.uuid,
             context.start_time,
             opts
           ) do
        {:ok, result} ->
          log_request(context, billing, request.urls, result)
          {:ok, add_billing(context.api_key, split, result)}

        # Accepted and still running. Charged at admission; the report is
        # collected later from GET /v1/analyze/{uuid}, which bills nothing.
        {:timeout, timed_out_uuid} ->
          {:incomplete,
           %{
             state: "incomplete",
             uuid: timed_out_uuid,
             error: "analysis did not complete within #{request.cache_timeout}ms timeout"
           }}

        {:error, error} ->
          {:error, error}
      end
    rescue
      error in LeiService.EnqueueError ->
        {:not_queued, not_queued(context.route, billing, split, error)}
    end
  end

  @doc """
  Gives back what admission charged for `split` and returns the body that
  says so.
  """
  # Charged at admission and the work never reached the queue: give the credits
  # back and say so, rather than letting the raise become a bare 500 with the
  # money kept (#217). Only LeiService.EnqueueError is rescued -- a request
  # whose work *was* queued and then failed some other way has been served.
  def not_queued(route, {org_id, _api_key_id, _tier}, split, error) do
    credits = credits_for(split)

    Logger.error("#{route}: #{Exception.message(error)}; returning #{credits} credits")

    Lei.Credits.credit_unqueued(org_id, credits, %{
      "route" => route,
      "uuid" => error.uuid
    })

    %{
      error: "analysis_not_queued",
      message: "the analysis could not be queued; you have not been charged",
      credits_returned: credits
    }
  end

  @job_id ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  The job `run/4` started, by its id: `{:ok, json}`, `{:not_found, message}`
  or `{:unavailable, message}`. Reading a job bills nothing -- the analysis
  was charged at admission.

  An incomplete job may be refreshed, at most once per job per window.
  """
  # A job is read by its id, which is the credential for it. Anything that is
  # not UUID-shaped is refused before Redis is asked: the id was used directly
  # as a key, so any value in the database could be read through this route.
  def job(uuid) when is_binary(uuid) do
    if Regex.match?(@job_id, uuid), do: read_job(uuid), else: job_not_found()
  end

  def job(_uuid), do: job_not_found()

  defp job_not_found, do: {:not_found, "invalid UUID provided, no job found."}

  defp read_job(uuid) do
    try do
      case LeiService.Datastore.get_job(uuid) do
        {:ok, job} ->
          job_obj = Poison.decode!(job)

          case job_obj["state"] do
            "complete" -> {:ok, job}
            _incomplete -> {:ok, refresh_incomplete(uuid, job, job_obj)}
          end

        {:error, _job} ->
          job_not_found()
      end
    rescue
      e ->
        # Logged in full, answered without detail: an exception's message can
        # carry internal state.
        Logger.error("Error fetching job #{uuid}: #{inspect(e)}")
        {:unavailable, "Internal error fetching job"}
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
            :lei_service,
            :job_refresher,
            &LeiService.Analysis.refresh_job/1
          )

        Poison.encode!(refresher.(job_obj))

      _ ->
        job
    end
  end

  defp cache_split(urls) when is_list(urls) do
    urls = Enum.filter(urls, &is_binary/1)
    hits = Enum.count(urls, &LeiService.Datastore.in_cache?/1)
    {hits, length(urls) - hits}
  end

  defp cache_split(_), do: {0, 0}

  defp credits_for({hits, misses}) do
    Lei.UsageTracker.calculate_cost(hits, misses)
    |> Decimal.mult(10)
    |> Decimal.round(0, :ceiling)
    |> Decimal.to_integer()
  end

  # Logged against the org the gate billed -- the key's, or the one a payment
  # on this request identified. Keyed on the API key alone, a paying agent's
  # first request was logged with no org, its URLs and all (#149).
  # Gate.admit/2 answers {:ok, conn, {org_id, api_key_id, tier}}. Anything else
  # is a path with no org -- an unauthenticated free analysis -- and crediting
  # nobody is correct there rather than an error.
  defp billing_org({org_id, _api_key_id, _tier}), do: org_id
  defp billing_org(_), do: nil

  defp log_request(context, {org_id, key_id, _tier}, urls, result) when is_binary(result) do
    org =
      case context.api_key do
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

    LeiService.RequestLogger.log_request(context.route, org, key_id, urls, cache_status)
  end

  defp log_request(_context, _billing, _urls, _result), do: :ok

  defp add_billing(nil, _split, result), do: result

  # From the split admission charged, not the response's cache counts. An
  # async or stale response carries no counts, so a block read from it told
  # the caller a charged miss had cost nothing.
  defp add_billing(api_key, {hits, misses}, result) when is_binary(result) do
    case Poison.decode(result) do
      {:ok, decoded} ->
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

  defp add_billing(_api_key, _split, result), do: result
end
