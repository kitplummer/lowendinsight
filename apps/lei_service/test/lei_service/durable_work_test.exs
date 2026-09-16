defmodule LeiService.DurableWorkTest do
  @moduledoc """
  Work whose loss matters is not fire-and-forget (ADR-004 step 5).

  `Task.start` returns `{:ok, pid}` immediately and the caller cannot tell
  whether the work happened: a crash or a deploy takes it silently. Billing
  is the case that matters most -- usage the ledger never sees is revenue
  lost -- and `record_usage_async/4` was exactly that shape. Nothing calls it
  any more (admission records usage in the request's transaction), so this
  keeps the shape from coming back.
  """
  use ExUnit.Case, async: true

  @service_lib Path.expand("../../lib", __DIR__)

  defp source(relative), do: File.read!(Path.join(@service_lib, relative))

  test "no billing function defers its write to an unsupervised task" do
    usage_tracker = source("lei/usage_tracker.ex")

    refute usage_tracker =~ "Task.start",
           "usage is money: a write that a restart can lose does not belong in a task"

    refute usage_tracker =~ "_async",
           "an async recording function invites the caller that loses the write"
  end

  test "usage is written in the same transaction that admits the request" do
    usage_tracker = source("lei/usage_tracker.ex")

    [admit] = Regex.run(~r/def admit_usage.*?\n  end\n/s, usage_tracker)
    assert admit =~ "Repo.transaction("
    assert admit =~ "lock_org!"
    assert admit =~ "write_usage("
  end

  test "a cached report's refresh is queued, not spawned, and does not block the response" do
    analysis = source("lei_service/analysis.ex")

    refute analysis =~ "Task.start(",
           "a refresh spawned in a task is lost on restart"

    assert analysis =~ "AnalysisSupervisor.enqueue("

    # perform_analysis/3 runs the analysis inline when workers are disabled;
    # a refresh of an answered request must not wait for it.
    supervisor = source("lei_service/analysis_supervisor.ex")
    [enqueue] = Regex.run(~r/def enqueue.*?\n  end\n/s, supervisor)
    assert enqueue =~ "Oban.insert()"
    refute enqueue =~ "Task.await"
  end

  test "the fire-and-forget sites that remain are only ones whose loss is harmless" do
    # api_keys touches last_used_at: losing one costs nothing (ADR-004).
    # The trending trigger is step 6.
    remaining =
      Path.wildcard(Path.join(@service_lib, "**/*.ex"))
      |> Enum.filter(&(File.read!(&1) =~ ~r/Task\.start(_link)?\(/))
      |> Enum.map(&Path.relative_to(&1, @service_lib))
      |> Enum.sort()

    assert remaining == ["lei/api_keys.ex", "lei_service/endpoint.ex"]
  end
end
