# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.
require Logger

defmodule LeiService.AnalysisSupervisor do
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
    if Application.get_env(:lei_service, :use_workers) do
      Logger.debug("queueing analysis job for #{uuid}")

      changeset =
        %{uuid: uuid, urls: urls, start_time: DateTime.to_iso8601(start_time)}
        |> LeiService.AnalysisWorker.new()

      # Both shapes the insert fails in, as one named error the routes can
      # single out (#217). A missing or drifted oban_jobs table raises from
      # Postgrex rather than returning an error tuple, so the case alone never
      # saw it -- it escaped as a 500 with the caller already charged.
      try do
        case Oban.insert(changeset) do
          {:ok, _job} ->
            Logger.debug("Job enqueued for #{uuid}")

          {:error, reason} ->
            raise LeiService.EnqueueError, uuid: uuid, reason: reason
        end
      rescue
        error in LeiService.EnqueueError ->
          Logger.error(Exception.message(error))
          reraise error, __STACKTRACE__

        error ->
          Logger.error("Failed to enqueue job for #{uuid}: #{inspect(error)}")
          reraise LeiService.EnqueueError.exception(uuid: uuid, reason: error), __STACKTRACE__
      end
    else
      try do
        task =
          Task.Supervisor.async(
            __MODULE__,
            LeiService.Analysis,
            :process,
            [uuid, urls, start_time],
            opts
          )

        Task.await(task, LeiService.GithubTrending.get_wait_time())
      catch
        :exit, _ -> raise RuntimeError, message: "Timed out processing local async job."
      end
    end

    {:ok, "collected analysis for cached repos, queued work for new repos - on job: #{uuid}"}
  end

  @doc """
  Queue an analysis without waiting for it.

  `perform_analysis/3` runs the work inline when workers are disabled, which
  is right for a request that must answer with a result. A background refresh
  of an already-answered request must not block it, and must survive a
  restart, so it is always a job (ADR-004).
  """
  def enqueue(uuid, urls, start_time) do
    %{uuid: uuid, urls: urls, start_time: DateTime.to_iso8601(start_time)}
    |> LeiService.AnalysisWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, job} ->
        Logger.debug("queued refresh for #{uuid} as job #{job.id}")
        {:ok, job}

      {:error, reason} ->
        Logger.error("could not queue refresh for #{uuid}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
