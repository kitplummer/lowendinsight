defmodule LeiService.TrendingScheduleWorker do
  @moduledoc """
  Queues one refresh job per language that is due.

  Trending ran under Quantum inside the web node: a run was lost on every
  restart and nothing recorded that it had happened. Splitting the run into
  one job per language also keeps any single job well inside Lifeline's
  rescue window -- a whole run has taken 95 minutes (ADR-004 step 6).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(2)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    opts = if args["force"], do: [force: true], else: []

    languages = due().(opts)
    Logger.info("trending: queueing #{length(languages)} language(s)")

    Enum.each(languages, fn language ->
      %{"language" => language}
      |> LeiService.TrendingRefreshWorker.new()
      |> Oban.insert()
      |> case do
        {:ok, _job} ->
          :ok

        {:error, reason} ->
          Logger.error("trending: could not queue #{language}: #{inspect(reason)}")
      end
    end)

    :ok
  end

  defp due do
    :lei_service
    |> Application.get_env(:trending_jobs, [])
    |> Keyword.get(:due, &LeiService.GithubTrending.due_languages/1)
  end
end
