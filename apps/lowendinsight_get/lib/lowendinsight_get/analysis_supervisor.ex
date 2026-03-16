# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.
require Logger

defmodule LowendinsightGet.AnalysisSupervisor do
  @moduledoc """
  AnalysisSupervisor manages the asynchronous processing of incoming requests,
  farming out the work to sub-processes to perform the actual analysis.
  """

  @doc """
  perform_analysis/3: takes in a job uuid, array of urls and the analysis start_time
  and creates a new process to run the LowEndInsight analysis.

  TODO: what to do if the process bonks?  need to track and restart job if process
  fails at any point, in a hard-way (not just an input error or handled error.)
  """
  def perform_analysis(uuid, urls, start_time) do
    opts = [restart: :transient]
    ## Only if use_workers is true
    if Application.get_env(:lowendinsight_get, :use_workers) do
      Logger.debug("queueing analysis job for #{uuid}")

      changeset =
        %{uuid: uuid, urls: urls, start_time: DateTime.to_iso8601(start_time)}
        |> LowendinsightGet.AnalysisWorker.new()

      case Oban.insert(changeset) do
        {:ok, _job} ->
          Logger.debug("Job enqueued for #{uuid}")

        {:error, changeset} ->
          Logger.error("Failed to enqueue job: #{inspect(changeset)}")
          raise RuntimeError, message: "Failed to queue the analysis job."
      end
    else
      try do
        task =
          Task.Supervisor.async(
            __MODULE__,
            LowendinsightGet.Analysis,
            :process,
            [uuid, urls, start_time],
            opts
          )

        Task.await(task, LowendinsightGet.GithubTrending.get_wait_time())
      catch
        :exit, _ -> raise RuntimeError, message: "Timed out processing local async job."
      end
    end

    {:ok, "collected analysis for cached repos, queued work for new repos - on job: #{uuid}"}
  end
end
