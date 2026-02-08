# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Workers.AnalysisWorker do
  @moduledoc """
  Async worker for analyzing dependencies that were not found in cache.

  Attempts to find a source repository for the dependency and run
  LowEndInsight analysis on it. Results are stored in the batch cache
  and the job registry is updated.
  """

  require Logger

  @doc """
  Performs analysis for a single dependency.
  """
  def perform(job_id, dep, _cache_mode) do
    Lei.Registry.update_job(job_id, :running)

    ecosystem = dep["ecosystem"]
    package = dep["package"]
    version = dep["version"]

    Logger.info("Analyzing #{ecosystem}/#{package}@#{version} (job: #{job_id})")

    case resolve_repo_url(ecosystem, package) do
      {:ok, url} ->
        {:ok, report} = AnalyzerModule.analyze(url, "lei-batch", %{types: true})
        result = extract_result(report, dep)
        Lei.BatchCache.put(ecosystem, package, version, result)
        Lei.Registry.update_job(job_id, :complete, result)

      {:error, reason} ->
        result = %{"error" => reason, "risk" => "undetermined"}
        Lei.Registry.update_job(job_id, :failed, result)
    end
  rescue
    e ->
      Logger.error("Worker failed for job #{job_id}: #{inspect(e)}")
      Lei.Registry.update_job(job_id, :failed, %{"error" => inspect(e)})
  end

  defp resolve_repo_url("npm", package) do
    {:ok, "https://github.com/#{infer_npm_repo(package)}"}
  end

  defp resolve_repo_url("hex", package) do
    {:ok, "https://github.com/#{infer_hex_repo(package)}"}
  end

  defp resolve_repo_url("pypi", package) do
    {:ok, "https://github.com/#{infer_pypi_repo(package)}"}
  end

  defp resolve_repo_url("crates", package) do
    {:ok, "https://github.com/#{infer_crates_repo(package)}"}
  end

  defp resolve_repo_url(ecosystem, package) do
    {:error, "Cannot resolve repo URL for #{ecosystem}/#{package}"}
  end

  defp extract_result(report, dep) do
    risk = get_in(report, [:data, :risk]) || "undetermined"
    results = get_in(report, [:data, :results]) || %{}

    %{
      "ecosystem" => dep["ecosystem"],
      "package" => dep["package"],
      "version" => dep["version"],
      "risk" => risk,
      "details" => %{
        "contributor_count" => results[:contributor_count],
        "contributor_risk" => results[:contributor_risk],
        "commit_currency_risk" => results[:commit_currency_risk],
        "large_recent_commit_risk" => results[:large_recent_commit_risk],
        "functional_contributors_risk" => results[:functional_contributors_risk],
        "sbom_risk" => results[:sbom_risk]
      }
    }
  end

  # Best-effort repo inference - these are heuristics
  defp infer_npm_repo(package), do: package
  defp infer_hex_repo(package), do: package
  defp infer_pypi_repo(package), do: package
  defp infer_crates_repo(package), do: package
end
