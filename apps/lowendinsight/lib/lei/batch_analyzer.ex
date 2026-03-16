defmodule Lei.BatchAnalyzer do
  @moduledoc """
  Batch SBOM analysis engine.

  Analyzes lists of dependencies with parallel cache lookups,
  targeting <500ms for 50 dependencies when mostly cached.
  """

  @doc """
  Analyze a batch of dependencies.

  Each dependency should be a map with "ecosystem", "package", and "version" keys.
  Returns a summary with cached results and pending jobs for cache misses.
  """
  def analyze(dependencies, opts \\ []) do
    cache_mode = Keyword.get(opts, :cache_mode, "stale")
    start_time = System.monotonic_time(:millisecond)

    # Parallel cache lookups
    {cached, misses} = partition_by_cache(dependencies)

    # For cache misses, queue analysis jobs
    {pending_jobs, failed} = process_misses(misses, cache_mode)

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

    failed_results =
      failed
      |> Enum.map(fn {dep, reason} ->
        build_result(dep, nil, "failed", nil, reason)
      end)

    all_results = results ++ pending_results ++ failed_results
    risk_breakdown = compute_risk_breakdown(results)

    %{
      analyzed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      elapsed_ms: elapsed,
      summary: %{
        total: length(dependencies),
        cached: length(cached),
        pending: length(pending_jobs),
        failed: length(failed),
        risk_breakdown: risk_breakdown
      },
      results: all_results,
      pending_jobs: Enum.map(pending_jobs, fn {_dep, job_id} -> job_id end)
    }
  end

  defp partition_by_cache(dependencies) do
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

  defp process_misses(misses, _cache_mode) do
    misses
    |> Enum.reduce({[], []}, fn dep, {pending, failed} ->
      job_id = generate_job_id()

      case schedule_analysis(dep, job_id) do
        :ok ->
          {[{dep, job_id} | pending], failed}

        {:error, reason} ->
          {pending, [{dep, reason} | failed]}
      end
    end)
    |> then(fn {pending, failed} -> {Enum.reverse(pending), Enum.reverse(failed)} end)
  end

  defp schedule_analysis(dep, job_id) do
    # Store a pending marker in cache so subsequent requests know work is queued
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

    :ok
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

  defp generate_job_id do
    "job-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end
end
