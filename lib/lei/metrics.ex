defmodule Lei.Metrics do
  @moduledoc """
  Prometheus-compatible metrics endpoint.

  Exposes BEAM VM metrics and application-specific counters
  in Prometheus exposition format.
  """

  @doc """
  Generate Prometheus exposition format text for all metrics.
  """
  def collect do
    vm_metrics() ++ app_metrics()
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp vm_metrics do
    memory = :erlang.memory()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    [
      "# HELP beam_memory_bytes BEAM memory usage in bytes",
      "# TYPE beam_memory_bytes gauge",
      "beam_memory_bytes{type=\"total\"} #{memory[:total]}",
      "beam_memory_bytes{type=\"processes\"} #{memory[:processes]}",
      "beam_memory_bytes{type=\"system\"} #{memory[:system]}",
      "beam_memory_bytes{type=\"atom\"} #{memory[:atom]}",
      "beam_memory_bytes{type=\"binary\"} #{memory[:binary]}",
      "beam_memory_bytes{type=\"ets\"} #{memory[:ets]}",
      "",
      "# HELP beam_process_count Number of BEAM processes",
      "# TYPE beam_process_count gauge",
      "beam_process_count #{:erlang.system_info(:process_count)}",
      "",
      "# HELP beam_uptime_seconds BEAM uptime in seconds",
      "# TYPE beam_uptime_seconds gauge",
      "beam_uptime_seconds #{div(uptime_ms, 1000)}",
      "",
      "# HELP beam_scheduler_count Number of scheduler threads",
      "# TYPE beam_scheduler_count gauge",
      "beam_scheduler_count #{:erlang.system_info(:schedulers_online)}"
    ]
  end

  defp app_metrics do
    cache_stats = Lei.BatchCache.stats()

    [
      "",
      "# HELP lei_cache_entries_total Total entries in batch cache",
      "# TYPE lei_cache_entries_total gauge",
      "lei_cache_entries_total #{cache_stats[:count] || 0}",
      "",
      "# HELP lei_cache_ecosystems Cache entries by ecosystem",
      "# TYPE lei_cache_ecosystems gauge",
      format_ecosystem_metrics(cache_stats[:ecosystems] || %{})
    ]
    |> List.flatten()
  end

  defp format_ecosystem_metrics(ecosystems) when map_size(ecosystems) == 0, do: []

  defp format_ecosystem_metrics(ecosystems) do
    Enum.map(ecosystems, fn {ecosystem, count} ->
      "lei_cache_ecosystems{ecosystem=\"#{ecosystem}\"} #{count}"
    end)
  end
end
