defmodule Lei.BatchSchedulingTest do
  @moduledoc """
  A batch miss is queued, or reported as not queued -- never promised.

  `schedule_analysis/2` wrote a "pending" marker with a generated id and
  returned :ok. Nothing was enqueued, so the caller polled an id that named
  no work and the marker expired five minutes later (ADR-004). The library
  has no queue: the caller supplies one.
  """
  use ExUnit.Case, async: false

  setup do
    Lei.BatchCache.clear()
    :ok
  end

  defp deps(n),
    do: for(i <- 1..n, do: %{"ecosystem" => "npm", "package" => "p#{i}", "version" => "1.0.0"})

  test "each miss is scheduled exactly once, and carries the scheduler's job id" do
    test_pid = self()

    schedule = fn dep ->
      send(test_pid, {:scheduled, dep["package"]})
      {:ok, "oban-#{dep["package"]}"}
    end

    result = Lei.BatchAnalyzer.analyze(deps(2), schedule: schedule)

    assert result.summary.pending == 2
    assert Enum.sort(result.pending_jobs) == ["oban-p1", "oban-p2"]
    assert_received {:scheduled, "p1"}
    assert_received {:scheduled, "p2"}
    refute_received {:scheduled, _}
  end

  test "without a scheduler a miss is not reported as pending" do
    result = Lei.BatchAnalyzer.analyze(deps(1))

    assert result.summary.pending == 0
    assert result.pending_jobs == []

    [only] = result.results
    assert only.status == "uncached"
    refute Map.has_key?(only, :job_id)
  end

  test "a scheduler that fails reports the dependency as failed, with the reason" do
    schedule = fn _dep -> {:error, :queue_unavailable} end
    result = Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)

    assert result.summary.pending == 0
    assert result.summary.failed == 1
    [only] = result.results
    assert only.status == "failed"
    assert only.error =~ "queue_unavailable"
  end

  test "cache_mode fresh re-analyses what is cached, rather than answering from cache" do
    Lei.BatchCache.put("npm", "p1", "1.0.0", %{"risk" => "low"})
    schedule = fn _dep -> {:ok, "oban-1"} end

    stale = Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)
    assert stale.summary.cached == 1
    assert stale.summary.pending == 0

    Lei.BatchCache.put("npm", "p1", "1.0.0", %{"risk" => "low"})
    fresh = Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule, cache_mode: "fresh")
    assert fresh.summary.cached == 0
    assert fresh.summary.pending == 1
  end

  test "cache_split prices a fresh request as work to be done, not as cache hits" do
    Lei.BatchCache.put("npm", "p1", "1.0.0", %{"risk" => "low"})

    assert Lei.BatchAnalyzer.cache_split(deps(1)) == {1, 0}
    assert Lei.BatchAnalyzer.cache_split(deps(1), cache_mode: "fresh") == {0, 1}
  end

  test "a scheduled miss leaves a pending marker so the next request does not queue it again" do
    schedule = fn _dep -> {:ok, "oban-1"} end
    Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)

    assert {:ok, entry} = Lei.BatchCache.get("npm", "p1", "1.0.0")
    assert entry.result.status == "pending"
    assert entry.result.job_id == "oban-1"
  end
end
