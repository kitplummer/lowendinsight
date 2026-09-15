defmodule LeiService.AnalysisWorker do
  use Oban.Worker,
    queue: :analysis,
    max_attempts: 3,
    unique: [period: 300, fields: [:args], keys: [:uuid]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"uuid" => uuid, "urls" => urls, "start_time" => start_time_str}}) do
    {:ok, start_time, _} = DateTime.from_iso8601(start_time_str)

    # process/3 raises on failure, which Oban records and retries.
    {:ok, _report} = LeiService.Analysis.process(uuid, urls, start_time)
    :ok
  end
end
