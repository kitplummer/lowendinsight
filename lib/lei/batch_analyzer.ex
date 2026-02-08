# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchAnalyzer do
  @moduledoc """
  Analyzes entire SBOMs in a single request with parallel cache lookups.

  For each dependency in the batch:
  1. Check the ETS batch cache for a cached result
  2. If cached, return immediately
  3. If not cached, queue an async analysis job

  Performance target: <500ms for 50 deps (mostly cache hits).
  """

  require Logger

  @doc """
  Analyzes a batch of dependencies.

  Returns a map with summary, results for cache hits, and job IDs for misses.
  """
  def analyze(deps, opts \\ []) do
    Lei.BatchCache.init()
    start_time = System.monotonic_time(:millisecond)

    cache_mode = Keyword.get(opts, :cache_mode, "stale")

    # Parallel cache lookups
    {cached, misses} = Lei.BatchCache.lookup_batch(deps)

    # Queue async jobs for cache misses
    pending_jobs =
      Enum.map(misses, fn dep ->
        job_id = Lei.Registry.create_job(dep)
        schedule_analysis(job_id, dep, cache_mode)
        job_id
      end)

    # Build results from cache hits
    results =
      Enum.map(cached, fn {dep, entry} ->
        %{
          "ecosystem" => dep["ecosystem"],
          "package" => dep["package"],
          "version" => dep["version"],
          "status" => "cached",
          "risk" => get_in(entry.result, ["risk"]) || get_in(entry.result, [:risk]) || "unknown",
          "cached_at" => format_timestamp(entry.cached_at),
          "analysis" => entry.result
        }
      end)

    # Build risk breakdown from cached results
    risk_breakdown = build_risk_breakdown(results)

    elapsed = System.monotonic_time(:millisecond) - start_time

    %{
      "analyzed_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "duration_ms" => elapsed,
      "summary" => %{
        "total" => length(deps),
        "cached" => length(cached),
        "pending" => length(misses),
        "failed" => 0,
        "risk_breakdown" => risk_breakdown
      },
      "results" => results,
      "pending_jobs" => pending_jobs
    }
  end

  defp schedule_analysis(job_id, dep, cache_mode) do
    Task.Supervisor.start_child(Lei.TaskSupervisor, fn ->
      Lei.Workers.AnalysisWorker.perform(job_id, dep, cache_mode)
    end)
  end

  defp build_risk_breakdown(results) do
    results
    |> Enum.map(fn r -> r["risk"] end)
    |> Enum.reduce(%{"low" => 0, "medium" => 0, "high" => 0, "critical" => 0}, fn risk, acc ->
      Map.update(acc, risk, 1, &(&1 + 1))
    end)
  end

  defp format_timestamp(unix_seconds) when is_integer(unix_seconds) do
    DateTime.from_unix!(unix_seconds) |> DateTime.to_iso8601()
  end

  defp format_timestamp(_), do: nil
end
