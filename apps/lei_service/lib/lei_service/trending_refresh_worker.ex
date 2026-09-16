defmodule LeiService.TrendingRefreshWorker do
  @moduledoc """
  Refreshes one language's trending report.

  On the `trending` queue, which runs one job at a time, so only one
  language's repositories are cloned at once -- the constraint that fourteen
  simultaneous analyses broke when the machine was OOM-killed (#158).
  """
  use Oban.Worker,
    queue: :trending,
    max_attempts: 2,
    priority: 3,
    unique: [period: 3600, fields: [:args], keys: [:language]]

  require Logger

  # One language, bounded below Lifeline's rescue_after (60m) so an overrun
  # fails and is visible rather than being rescued while still running.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(40)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"language" => language}}) do
    case refresh().(language, []) do
      {:ok, uuid} ->
        Logger.info("trending: #{language} refreshed as #{uuid}")
        :ok

      {:error, reason} ->
        {:error, "trending #{language}: #{inspect(reason)}"}
    end
  end

  defp refresh do
    :lei_service
    |> Application.get_env(:trending_jobs, [])
    |> Keyword.get(:refresh, &LeiService.GithubTrending.refresh/2)
  end
end
