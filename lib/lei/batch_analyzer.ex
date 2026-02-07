# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.BatchAnalyzer do
  @moduledoc """
  Coordinates batch SBOM dependency analysis.

  Checks the batch cache for each dependency, returns cached results
  immediately, and enqueues Oban jobs for cache misses.
  """

  @spec analyze(list(map())) :: map()
  def analyze(dependencies) when is_list(dependencies) do
    start_time = DateTime.utc_now()

    {cached, pending, failed} =
      dependencies
      |> Task.async_stream(&check_or_enqueue/1,
        max_concurrency: System.schedulers_online() * 2,
        timeout: 10_000
      )
      |> Enum.reduce({[], [], []}, fn
        {:ok, {:cached, result}}, {c, p, f} ->
          {[result | c], p, f}

        {:ok, {:pending, job_id}}, {c, p, f} ->
          {c, [job_id | p], f}

        {:ok, {:failed, error}}, {c, p, f} ->
          {c, p, [error | f]}

        {:exit, _reason}, {c, p, f} ->
          {c, p, [%{"error" => "task_timeout"} | f]}
      end)

    cached = Enum.reverse(cached)
    pending = Enum.reverse(pending)
    failed = Enum.reverse(failed)

    risk_breakdown = compute_risk_breakdown(cached)

    %{
      "analyzed_at" => DateTime.to_iso8601(start_time),
      "summary" => %{
        "total" => length(dependencies),
        "cached" => length(cached),
        "pending" => length(pending),
        "failed" => length(failed),
        "risk_breakdown" => risk_breakdown
      },
      "results" => cached,
      "pending_jobs" => pending
    }
  end

  defp check_or_enqueue(%{"ecosystem" => ecosystem, "package" => package} = dep) do
    version = Map.get(dep, "version", "latest")

    case Lei.BatchCache.get(ecosystem, package, version) do
      {:ok, result} ->
        {:cached, result}

      :miss ->
        args = %{"ecosystem" => ecosystem, "package" => package, "version" => version}

        case Oban.insert(Lei.Workers.AnalysisWorker.new(args)) do
          {:ok, %Oban.Job{id: id}} ->
            {:pending, "job-#{id}"}

          {:error, reason} ->
            {:failed, %{
              "ecosystem" => ecosystem,
              "package" => package,
              "version" => version,
              "error" => inspect(reason)
            }}
        end
    end
  end

  defp compute_risk_breakdown(results) do
    results
    |> Enum.map(fn r -> Map.get(r, "risk", "undetermined") end)
    |> Enum.reduce(%{}, fn risk, acc -> Map.update(acc, risk, 1, &(&1 + 1)) end)
  end
end
