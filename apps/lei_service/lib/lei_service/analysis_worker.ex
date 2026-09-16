defmodule LeiService.AnalysisWorker do
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:uuid]]

  # A job that can run forever is indistinguishable from one that is stuck:
  # Lifeline rescues it after an hour and the retry hangs the same way. The
  # budget grows with the repositories to analyse and is capped below
  # Lifeline's rescue_after, so a timeout is a failure Oban records and
  # retries rather than a rescue (ADR-004).
  @base_minutes 2
  @per_url_minutes 3
  @max_minutes 45

  @impl Oban.Worker
  def timeout(%Oban.Job{args: args}) do
    urls = Map.get(args, "urls", [])
    minutes = min(@base_minutes + @per_url_minutes * length(urls), @max_minutes)
    :timer.minutes(minutes)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uuid" => uuid, "urls" => urls, "start_time" => start_time_str}}) do
    {:ok, start_time, _} = DateTime.from_iso8601(start_time_str)

    # process/3 raises on failure, which Oban records and retries.
    {:ok, _report} = LeiService.Analysis.process(uuid, urls, start_time)
    :ok
  end
end
