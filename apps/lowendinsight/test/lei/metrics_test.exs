defmodule Lei.MetricsTest do
  # Not async, and the sandbox is checked out: the reconciliation and metering
  # gauges query the database. Without a connection they raise, get rescued,
  # and emit measure="error" -- so the assertions below would have passed on an
  # endpoint that reports nothing but errors, while filling the test output
  # with ownership stack traces.
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  test "collect returns prometheus format text" do
    output = Lei.Metrics.collect()
    assert is_binary(output)
    assert output =~ "beam_memory_bytes"
    assert output =~ "beam_process_count"
    assert output =~ "beam_uptime_seconds"
    assert output =~ "beam_scheduler_count"
    assert output =~ "lei_cache_entries_total"
  end

  test "includes TYPE and HELP annotations" do
    output = Lei.Metrics.collect()
    assert output =~ "# HELP beam_memory_bytes"
    assert output =~ "# TYPE beam_memory_bytes gauge"
    assert output =~ "# TYPE beam_process_count gauge"
  end

  test "memory metrics have type labels" do
    output = Lei.Metrics.collect()
    assert output =~ ~r/beam_memory_bytes\{type="total"\} \d+/
    assert output =~ ~r/beam_memory_bytes\{type="processes"\} \d+/
    assert output =~ ~r/beam_memory_bytes\{type="system"\} \d+/
  end

  test "process count is a positive integer" do
    output = Lei.Metrics.collect()
    [_, count] = Regex.run(~r/beam_process_count (\d+)/, output)
    assert String.to_integer(count) > 0
  end

  describe "database-backed gauges" do
    test "reconciliation reports real measures, not an error" do
      output = Lei.Metrics.collect()

      for measure <- ~w(drifting_rows drift_credits reconciled_rows pre_ledger_rows) do
        assert output =~ "lei_credit_reconciliation{measure=\"#{measure}\"}",
               "missing #{measure}"
      end

      refute output =~ "lei_credit_reconciliation{measure=\"error\"}"
    end

    test "metering reports real measures, not an error" do
      output = Lei.Metrics.collect()

      for measure <- ~w(reported failed unreported unreported_credits metered_orgs) do
        assert output =~ "lei_stripe_metering{measure=\"#{measure}\"}", "missing #{measure}"
      end

      refute output =~ "lei_stripe_metering{measure=\"error\"}"
    end
  end
end
