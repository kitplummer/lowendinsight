defmodule Lei.BatchAnalyzer do
  @moduledoc """
  Batch SBOM analysis engine.

  Analyzes lists of dependencies with parallel cache lookups,
  targeting <500ms for 50 dependencies when mostly cached.
  """

  @doc """
  Analyze a batch of dependencies.

  Each dependency should be a map with "ecosystem", "package", and "version" keys.
  Returns a summary with cached results, and for each miss either a queued job
  or the reason there is none.

  Options:
    * `:schedule` - a function taking the dependency and returning
      `{:ok, job_id}` or `{:error, reason}`. This library has no queue; the
      caller supplies one (ADR-004). Without it a miss is reported as
      `"uncached"`: it is not analysed, and no job id is invented for it.
    * `:cache_mode` - `"stale"` (default) or `"fresh"`.
  """
  def analyze(dependencies, opts \\ []) do
    cache_mode = Keyword.get(opts, :cache_mode, "stale")
    schedule = Keyword.get(opts, :schedule)
    start_time = System.monotonic_time(:millisecond)

    # Parallel cache lookups
    {cached, misses} = partition_by_cache(dependencies, cache_mode)

    # For cache misses, queue analysis jobs through the caller's scheduler
    {pending_jobs, uncached, failed} = process_misses(misses, schedule)

    elapsed = System.monotonic_time(:millisecond) - start_time

    results =
      cached
      |> Enum.map(fn {dep, entry} ->
        build_result(dep, entry.result, "cached")
      end)

    pending_results =
      pending_jobs
      |> Enum.map(fn {dep, job_id} ->
        build_result(dep, nil, "pending", job_id)
      end)

    uncached_results =
      uncached
      |> Enum.map(fn dep -> build_result(dep, nil, "uncached") end)

    failed_results =
      failed
      |> Enum.map(fn {dep, reason} ->
        build_result(dep, nil, "failed", nil, reason)
      end)

    all_results = results ++ pending_results ++ uncached_results ++ failed_results
    risk_breakdown = compute_risk_breakdown(results)

    %{
      analyzed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      elapsed_ms: elapsed,
      summary: %{
        total: length(dependencies),
        cached: length(cached),
        pending: length(pending_jobs),
        uncached: length(uncached),
        failed: length(failed),
        risk_breakdown: risk_breakdown
      },
      results: all_results,
      pending_jobs: Enum.map(pending_jobs, fn {_dep, job_id} -> job_id end)
    }
  end

  @doc """
  `{hits, misses}` for a batch, before any work: what admission prices it at.
  The same lookup `analyze/2` partitions on.
  """
  def cache_split(dependencies, opts \\ []) do
    {cached, misses} = partition_by_cache(dependencies, Keyword.get(opts, :cache_mode, "stale"))
    {length(cached), length(misses)}
  end

  # "fresh" asks for the analysis to be run again, so nothing counts as
  # cached -- neither for the results nor for what the work costs.
  defp partition_by_cache(dependencies, "fresh"), do: {[], dependencies}

  defp partition_by_cache(dependencies, _cache_mode) do
    dependencies
    |> Enum.reduce({[], []}, fn dep, {cached, misses} ->
      case Lei.BatchCache.get(dep["ecosystem"], dep["package"], dep["version"]) do
        {:ok, entry} ->
          {[{dep, entry} | cached], misses}

        {:error, _} ->
          {cached, [dep | misses]}
      end
    end)
    |> then(fn {cached, misses} -> {Enum.reverse(cached), Enum.reverse(misses)} end)
  end

  # Without a scheduler there is nothing to queue the work: say so, rather
  # than reporting a job that does not exist.
  defp process_misses(misses, nil), do: {[], misses, []}

  defp process_misses(misses, schedule) when is_function(schedule, 1) do
    misses
    |> Enum.reduce({[], [], []}, fn dep, {pending, uncached, failed} ->
      case schedule.(dep) do
        {:ok, job_id} ->
          mark_pending(dep, job_id)
          {[{dep, job_id} | pending], uncached, failed}

        {:error, reason} ->
          {pending, uncached, [{dep, reason} | failed]}
      end
    end)
    |> then(fn {pending, uncached, failed} ->
      {Enum.reverse(pending), Enum.reverse(uncached), Enum.reverse(failed)}
    end)
  end

  # So a second request for the same dependency sees work already queued
  # rather than queueing it again.
  defp mark_pending(dep, job_id) do
    Lei.BatchCache.put(
      dep["ecosystem"],
      dep["package"],
      dep["version"],
      %{
        status: "pending",
        job_id: job_id,
        queued_at: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      ttl: 300
    )
  end

  defp build_result(dep, analysis, status, job_id \\ nil, error \\ nil) do
    result = %{
      ecosystem: dep["ecosystem"],
      package: dep["package"],
      version: dep["version"],
      status: status
    }

    result =
      if analysis && status == "cached" do
        risk = extract_risk(analysis)
        Map.merge(result, %{risk: risk, analysis: analysis})
      else
        result
      end

    result = if job_id, do: Map.put(result, :job_id, job_id), else: result
    if error, do: Map.put(result, :error, inspect(error)), else: result
  end

  defp extract_risk(analysis) when is_map(analysis) do
    cond do
      Map.has_key?(analysis, :risk) -> analysis.risk
      Map.has_key?(analysis, "risk") -> analysis["risk"]
      Map.has_key?(analysis, :data) -> get_in(analysis, [:data, :risk])
      Map.has_key?(analysis, "data") -> get_in(analysis, ["data", "risk"])
      true -> "unknown"
    end
  end

  defp extract_risk(_), do: "unknown"

  defp compute_risk_breakdown(cached_results) do
    cached_results
    |> Enum.reduce(%{"low" => 0, "medium" => 0, "high" => 0, "critical" => 0}, fn result, acc ->
      risk = result[:risk] || "unknown"

      if Map.has_key?(acc, risk) do
        Map.update!(acc, risk, &(&1 + 1))
      else
        Map.put(acc, risk, 1)
      end
    end)
  end
end
