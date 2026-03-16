defmodule Lei.MetricsTest do
  use ExUnit.Case, async: true

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
end
