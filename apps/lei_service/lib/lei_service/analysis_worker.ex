defmodule LeiService.AnalysisWorker do
  require Logger

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
  def perform(%Oban.Job{
        args: %{"uuid" => uuid, "urls" => urls, "start_time" => start_time_str} = args
      }) do
    {:ok, start_time, _} = DateTime.from_iso8601(start_time_str)

    # process/3 raises on failure, which Oban records and retries.
    {:ok, report} = LeiService.Analysis.process(uuid, urls, start_time)

    refund_undetermined(report, args["org_id"])
    :ok
  end

  # Admission charged a cache miss for each of these before any analysis ran,
  # and an analysis that could not clone returns a report whose every metric is
  # nil (#255). The outcome is only known here, so the money is given back here
  # -- the same shape as adjustment:unqueued for work that never started (#217).
  #
  # Counted from the finished report rather than tracked during the run: the
  # report is what the requester received, so it cannot disagree with what they
  # were given.
  @doc false
  def refund_undetermined(report, org_id) do
    undetermined =
      report
      |> Map.get(:report, %{})
      |> Map.get(:repos, [])
      |> Enum.reject(&AnalyzerModule.determined?/1)
      |> length()

    cond do
      undetermined == 0 ->
        :ok

      is_nil(org_id) ->
        # Enqueued before org_id was carried, or by a path with no org. An
        # entry written against nobody is worse than no entry.
        Logger.warning("#{undetermined} analyses determined nothing with no org to credit")
        :ok

      true ->
        Logger.warning("#{undetermined} analyses determined nothing; crediting back")

        Lei.Credits.credit_undetermined(
          org_id,
          Lei.Credits.cost_in_credits(0, undetermined),
          %{"undetermined" => undetermined}
        )

        :ok
    end
  end
end
