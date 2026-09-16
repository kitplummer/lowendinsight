defmodule LeiService.CacheCleanerWorker do
  @moduledoc """
  Expires cached reports past their TTL, every five minutes.

  Ran under Quantum in the web node; now a job, so a run that does not happen
  is visible in `oban_jobs` rather than nowhere (ADR-004 step 6).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if Application.get_env(:lei_service, :cache_clean_enable) do
      clean().()
    else
      Logger.debug("cache cleaning disabled")
    end

    :ok
  end

  defp clean do
    :lei_service
    |> Application.get_env(:trending_jobs, [])
    |> Keyword.get(:clean, &LeiService.CacheCleaner.clean/0)
  end
end
