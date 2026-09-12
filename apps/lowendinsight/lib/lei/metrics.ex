defmodule Lei.Metrics do
  @moduledoc """
  Prometheus-compatible metrics endpoint.
  """

  def collect do
    (vm_metrics() ++ app_metrics())
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
      format_ecosystem_metrics(cache_stats[:ecosystems] || %{}),
      "",
      # A wrong signing secret is indistinguishable from an unset one from the
      # outside: every delivery 400s and nothing else changes. These counters
      # are how monitoring sees it. "unsigned" is scanners hitting a public
      # URL and is deliberately not an error signal.
      "# HELP lei_stripe_webhook_total Stripe webhook verification outcomes since boot",
      "# TYPE lei_stripe_webhook_total counter",
      webhook_metrics(),
      "",
      # The ledger is only worth having if a discrepancy is visible. Exposed
      # here because /metrics is already scraped every 15 minutes, and a
      # dashboard nobody opens is not monitoring.
      #
      # Aggregates only: no org identities, no balances. This endpoint is
      # public.
      "# HELP lei_credit_reconciliation Ledger agreement with recorded usage",
      "# TYPE lei_credit_reconciliation gauge",
      reconciliation_metrics()
    ]
    |> List.flatten()
  end

  defp reconciliation_metrics do
    report = Lei.Reconciliation.usage_vs_credits()

    [
      "lei_credit_reconciliation{measure=\"drifting_rows\"} #{report.drifting_rows}",
      "lei_credit_reconciliation{measure=\"drift_credits\"} #{report.drift_credits}",
      "lei_credit_reconciliation{measure=\"reconciled_rows\"} #{report.reconciled_rows}",
      "lei_credit_reconciliation{measure=\"pre_ledger_rows\"} #{report.pre_ledger_rows}"
    ]
  rescue
    # A metrics endpoint must not fail because one gauge cannot be computed --
    # it is what monitoring uses to decide everything else is alright. Emitting
    # -1 rather than omitting the series: a gauge that vanishes looks like
    # "nothing to report", and this one vanishing means the opposite.
    error ->
      require Logger
      Logger.error("Reconciliation metrics failed: #{inspect(error)}")
      ["lei_credit_reconciliation{measure=\"error\"} 1"]
  end

  defp webhook_metrics do
    stats = Lei.WebhookStats.all()

    Enum.map(Lei.WebhookStats.outcomes(), fn outcome ->
      "lei_stripe_webhook_total{result=\"#{outcome}\"} #{Map.get(stats, outcome, 0)}"
    end)
  end

  defp format_ecosystem_metrics(ecosystems) when map_size(ecosystems) == 0, do: []

  defp format_ecosystem_metrics(ecosystems) do
    Enum.map(ecosystems, fn {ecosystem, count} ->
      "lei_cache_ecosystems{ecosystem=\"#{ecosystem}\"} #{count}"
    end)
  end
end
