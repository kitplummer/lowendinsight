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

  # The pending marker is a cache entry, so partition_by_cache counted it as a
  # hit: asking again while the job ran returned status "cached" with the
  # marker as its "analysis" and no risk, and admission billed it as a cache
  # hit. A client polling for its result was charged per poll for nothing.
  describe "asking again while the analysis is queued" do
    setup do
      schedule = fn dep -> {:ok, "oban-#{dep["package"]}"} end
      Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)
      %{schedule: schedule}
    end

    test "reports it pending, with the same job", %{schedule: schedule} do
      [again] = Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule).results

      assert again.status == "pending"
      assert again.job_id == "oban-p1"
      refute Map.has_key?(again, :analysis)
    end

    test "is priced as neither a hit nor a miss" do
      assert Lei.BatchAnalyzer.cache_split(deps(1)) == {0, 0}
    end

    test "does not queue it a second time" do
      test_pid = self()

      schedule = fn dep ->
        send(test_pid, {:scheduled, dep["package"]})
        {:ok, "x"}
      end

      Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)
      refute_received {:scheduled, _}
    end
  end

  # The service's worker cancelled a package it could not resolve and recorded
  # nothing, so the marker read "pending" for five minutes, then "uncached",
  # and the next request queued it again -- forever, and a client polling for
  # it waited out its timeout with no reason given.
  describe "a dependency recorded as unresolvable" do
    setup do
      Lei.BatchAnalyzer.mark_unresolvable(hd(deps(1)), :no_repository)
      :ok
    end

    test "is reported failed, with the reason" do
      [only] = Lei.BatchAnalyzer.analyze(deps(1), schedule: fn _ -> {:ok, "x"} end).results

      assert only.status == "failed"
      assert only.error =~ "no_repository"
    end

    test "is not queued again, or charged" do
      test_pid = self()

      schedule = fn dep ->
        send(test_pid, {:scheduled, dep["package"]})
        {:ok, "x"}
      end

      Lei.BatchAnalyzer.analyze(deps(1), schedule: schedule)

      refute_received {:scheduled, _}
      assert Lei.BatchAnalyzer.cache_split(deps(1)) == {0, 0}
    end
  end
end
