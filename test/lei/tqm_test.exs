defmodule Lei.TQMTest do
  use ExUnit.Case, async: false

  setup do
    name = :"tqm_test_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Lei.TQM.start_link(name: name, window_size: 5, threshold: 0.5, min_sample: 1)
    %{tqm: pid}
  end

  test "circuit starts closed", %{tqm: tqm} do
    assert Lei.TQM.circuit_state(tqm) == :closed
  end

  test "circuit stays closed with only successes", %{tqm: tqm} do
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_success(tqm)
    assert Lei.TQM.circuit_state(tqm) == :closed
  end

  test "circuit opens when success rate drops below threshold", %{tqm: tqm} do
    # 0/2 = 0.0% < 50% threshold
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open
  end

  test "circuit stays open after more failures", %{tqm: tqm} do
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open
  end

  test "mixed results: circuit opens when rate drops below threshold", %{tqm: tqm} do
    # 1 success then 3 failures => 1/4 = 25% < 50%
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open
  end

  test "circuit stays closed when rate is at or above threshold", %{tqm: tqm} do
    # 1/2 = 50% == threshold, should stay closed
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :closed
  end

  test "sliding window evicts oldest outcomes", %{tqm: tqm} do
    # Fill with failures to open
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open

    # Start a fresh server to test window eviction in isolation
    name2 = :"tqm_window_#{:erlang.unique_integer([:positive])}"
    {:ok, tqm2} = Lei.TQM.start_link(name: name2, window_size: 3, threshold: 0.5, min_sample: 1)
    # 3 successes fills the window
    Lei.TQM.record_success(tqm2)
    Lei.TQM.record_success(tqm2)
    Lei.TQM.record_success(tqm2)
    # Then 2 failures — oldest success gets pushed out, window: [fail, fail, success] => 1/3 < 50%
    Lei.TQM.record_failure(tqm2)
    Lei.TQM.record_failure(tqm2)
    assert Lei.TQM.circuit_state(tqm2) == :open
  end

  test "status returns expected fields", %{tqm: tqm} do
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_failure(tqm)

    status = Lei.TQM.status(tqm)

    assert status.circuit in ["open", "closed"]
    assert is_float(status.success_rate)
    assert is_float(status.threshold_pct)
    assert is_integer(status.window_count)
    assert is_integer(status.total_runs)
    assert is_integer(status.total_successes)
    assert status.total_runs == 2
    assert status.total_successes == 1
  end

  test "status reports correct success rate", %{tqm: tqm} do
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_success(tqm)
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)

    status = Lei.TQM.status(tqm)
    assert status.success_rate == 50.0
  end

  test "circuit auto-resets after reset_after_ms", %{} do
    name = :"tqm_reset_#{:erlang.unique_integer([:positive])}"
    {:ok, tqm} = Lei.TQM.start_link(name: name, min_sample: 1, threshold: 0.5, reset_after_ms: 50)

    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open

    Process.sleep(60)
    assert Lei.TQM.circuit_state(tqm) == :closed
  end

  test "min_sample prevents circuit from opening prematurely" do
    name = :"tqm_minsample_#{:erlang.unique_integer([:positive])}"
    {:ok, tqm} = Lei.TQM.start_link(name: name, min_sample: 3, threshold: 0.5)

    # Only 2 failures — below min_sample of 3
    Lei.TQM.record_failure(tqm)
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :closed

    # Third failure hits min_sample — circuit opens
    Lei.TQM.record_failure(tqm)
    assert Lei.TQM.circuit_state(tqm) == :open
  end

  test "total_runs and total_successes accumulate across window rollovers" do
    name = :"tqm_totals_#{:erlang.unique_integer([:positive])}"
    {:ok, tqm} = Lei.TQM.start_link(name: name, window_size: 2, threshold: 0.1, min_sample: 1)

    for _ <- 1..5, do: Lei.TQM.record_success(tqm)

    status = Lei.TQM.status(tqm)
    assert status.total_runs == 5
    assert status.total_successes == 5
    # Window only holds last 2
    assert status.window_count == 2
  end
end
