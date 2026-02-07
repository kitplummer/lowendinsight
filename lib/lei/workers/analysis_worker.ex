# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Workers.AnalysisWorker do
  use Oban.Worker, queue: :analysis, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"ecosystem" => ecosystem, "package" => package, "version" => version}}) do
    case Lei.Registry.resolve_repo_url(ecosystem, package) do
      {:ok, repo_url} ->
        {:ok, report} = AnalyzerModule.analyze(repo_url, "batch_api", %{types: true})

        result = %{
          "ecosystem" => ecosystem,
          "package" => package,
          "version" => version,
          "report" => report,
          "risk" => get_in(report, [:data, :risk]) || "undetermined"
        }

        Lei.BatchCache.put(ecosystem, package, version, result)
        :ok

      {:error, reason} ->
        result = %{
          "ecosystem" => ecosystem,
          "package" => package,
          "version" => version,
          "error" => reason,
          "risk" => "undetermined"
        }

        Lei.BatchCache.put(ecosystem, package, version, result)
        :ok
    end
  end
end
