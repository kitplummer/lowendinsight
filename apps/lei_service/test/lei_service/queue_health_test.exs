defmodule LeiService.QueueHealthTest do
  @moduledoc """
  Stuck and backed-up background work is visible.

  Production ran Oban with no plugins and 79 jobs sat `executing` for days
  (#194). Every check was green throughout: the analyses those jobs promised
  simply never happened. Readiness now reports the queue, so the monitor's
  "degraded" alert covers it.
  """
  use ExUnit.Case, async: false

  alias LeiService.QueueHealth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(LeiService.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(LeiService.Repo, {:shared, self()})
    :ok
  end

  defp insert_job(state, opts) do
    ago = fn minutes ->
      DateTime.utc_now() |> DateTime.add(-minutes * 60) |> DateTime.to_naive()
    end

    attempted = opts[:attempted_minutes_ago] && ago.(opts[:attempted_minutes_ago])
    scheduled = ago.(opts[:scheduled_minutes_ago] || 0)

    Ecto.Adapters.SQL.query!(
      LeiService.Repo,
      "INSERT INTO oban_jobs (state, queue, worker, args, attempt, max_attempts, scheduled_at, attempted_at, attempted_by) " <>
        "VALUES ($1::oban_job_state, 'analysis', 'LeiService.AnalysisWorker', '{}'::jsonb, $2, 3, $3, $4, $5)",
      [
        state,
        if(attempted, do: 1, else: 0),
        scheduled,
        attempted,
        if(attempted, do: ["n"], else: nil)
      ]
    )
  end

  test "an empty queue is ok" do
    assert QueueHealth.status() == "ok"
    assert %{available: 0, executing: 0, stuck: 0} = QueueHealth.snapshot()
  end

  test "work in progress is ok" do
    insert_job("executing", attempted_minutes_ago: 5)
    insert_job("available", scheduled_minutes_ago: 1)

    assert QueueHealth.status() == "ok"
    assert %{available: 1, executing: 1, stuck: 0} = QueueHealth.snapshot()
  end

  test "a job executing past the stuck threshold is not ok" do
    insert_job("executing", attempted_minutes_ago: 91)

    assert QueueHealth.status() =~ "executing"
    assert QueueHealth.status() != "ok"
    assert %{stuck: 1} = QueueHealth.snapshot()
  end

  test "work queued but never started is not ok" do
    insert_job("available", scheduled_minutes_ago: 30)

    assert QueueHealth.status() =~ "waiting"
    assert %{available: 1, oldest_available_seconds: seconds} = QueueHealth.snapshot()
    assert seconds >= 1800
  end

  test "a job scheduled for later is not a backlog" do
    ahead = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_naive()

    Ecto.Adapters.SQL.query!(
      LeiService.Repo,
      "INSERT INTO oban_jobs (state, queue, worker, args, attempt, max_attempts, scheduled_at) " <>
        "VALUES ('scheduled'::oban_job_state, 'analysis', 'LeiService.AnalysisWorker', '{}'::jsonb, 0, 3, $1)",
      [ahead]
    )

    assert QueueHealth.status() == "ok"
  end

  test "an available job not yet due is not a backlog" do
    # Oban's stager makes a job available when it comes due, but a row can be
    # available and dated ahead (a direct insert, or clock skew between nodes).
    # Counting it would report a backlog, with a negative age.
    ahead = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_naive()

    Ecto.Adapters.SQL.query!(
      LeiService.Repo,
      "INSERT INTO oban_jobs (state, queue, worker, args, attempt, max_attempts, scheduled_at) " <>
        "VALUES ('available'::oban_job_state, 'analysis', 'LeiService.AnalysisWorker', '{}'::jsonb, 0, 3, $1)",
      [ahead]
    )

    assert QueueHealth.status() == "ok"
    assert %{available: 0, oldest_available_seconds: 0} = QueueHealth.snapshot()
  end

  test "a query that cannot run is an error, not an ok" do
    assert QueueHealth.status(repo: __MODULE__.NoSuchRepo) =~ "error"
  end

  test "metrics report the queue as gauges" do
    insert_job("executing", attempted_minutes_ago: 91)
    insert_job("available", scheduled_minutes_ago: 2)
    metrics = QueueHealth.metrics() |> Enum.join("\n")

    assert metrics =~ "# TYPE lei_queue_jobs gauge"
    assert metrics =~ ~s(lei_queue_jobs{state="executing"} 1)
    assert metrics =~ ~s(lei_queue_jobs{state="available"} 1)
    assert metrics =~ "lei_queue_stuck_jobs 1"
    assert metrics =~ "lei_queue_oldest_available_seconds"
  end
end
