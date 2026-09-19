defmodule Lei.Metrics do
  @moduledoc """
  Prometheus-compatible metrics endpoint.
  """

  def collect do
    (vm_metrics() ++ app_metrics() ++ registered_metrics())
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
      # One series, value 1, labelled with the mode the key is in. Derived from
      # the key, so a half-flipped deploy shows the key's truth here.
      "# HELP lei_stripe_mode Stripe mode of the configured secret key",
      "# TYPE lei_stripe_mode gauge",
      "lei_stripe_mode{mode=\"#{Lei.Stripe.Mode.current()}\"} 1",
      "",
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
      # Money that went back to customers, from the ledger itself, so it
      # survives a restart. Every rail and kind is listed at zero, so "none
      # yet" reads differently from "not collected".
      "# HELP lei_credit_reversals Credits taken back by refunds and disputes, and given back by won disputes",
      "# TYPE lei_credit_reversals gauge",
      reversal_metrics(),
      "",
      # A refund or dispute Stripe made that matched no credit purchase. Either
      # it was never a credit purchase (a Pro invoice) or the ledger lookup
      # missed one; the second is money Stripe returned that the ledger still
      # counts as spendable.
      "# HELP lei_stripe_reversal_events_total Refund and dispute events by outcome since boot",
      "# TYPE lei_stripe_reversal_events_total counter",
      reversal_event_metrics(),
      "",
      # The payment path by rail, from Postgres so a deploy does not reset it
      # (#139). A rail issuing challenges and settling none is broken; a spike
      # in challenge_mismatch refusals is someone forging credentials.
      "# HELP lei_payment_outcomes Payment challenges and credentials by rail, outcome and reason, last 24 hours",
      "# TYPE lei_payment_outcomes gauge",
      payment_outcome_metrics(),
      "",
      # 1 on, 0 off. A path left off after an incident is revenue stopped by
      # choice and then forgotten.
      "# HELP lei_payment_switch_enabled Whether each payment path's kill switch is on",
      "# TYPE lei_payment_switch_enabled gauge",
      switch_metrics(),
      "",
      # Money received while a rail was off and not yet credited or refunded.
      "# HELP lei_payment_held Payments held while their rail was switched off, awaiting credit or refund",
      "# TYPE lei_payment_held gauge",
      held_metrics(),
      "",
      # The ledger's purchases against the payments Stripe received, from the
      # latest hourly run (#139). A failed run reports failed and no
      # discrepancy count, so it cannot read as a clean one; age_seconds shows
      # a run that has stopped happening.
      "# HELP lei_stripe_reconciliation Ledger purchases against Stripe payments, latest run",
      "# TYPE lei_stripe_reconciliation gauge",
      stripe_reconciliation_metrics(),
      "",
      "# HELP lei_credit_reconciliation Ledger agreement with recorded usage",
      "# TYPE lei_credit_reconciliation gauge",
      reconciliation_metrics(),
      "",
      # Whether metered usage reached Stripe. Only the half we can answer
      # without asking Stripe: did our call succeed, and was it made.
      "# HELP lei_stripe_metering Metered usage reported to Stripe",
      "# TYPE lei_stripe_metering gauge",
      metering_metrics(),
      "",
      # Should stay at zero: the database and both changesets refuse to create
      # one. Published because a row that predates the constraint, or an
      # operator editing the database directly, still has to be visible.
      "# HELP lei_unbilled_pro_orgs Active pro organisations that cannot be billed",
      "# TYPE lei_unbilled_pro_orgs gauge",
      unbilled_pro_metrics(),
      "",
      # Work charged for at admission that never reached the queue and was
      # credited back (#217). Counted from the ledger rather than a counter at
      # the point of failure: a process-local counter resets on boot and can
      # disagree with what was written, while these entries are the durable
      # record of exactly this.
      "# HELP lei_unqueued_credits Credits returned for work that could not be queued",
      "# TYPE lei_unqueued_credits gauge",
      unqueued_credit_metrics()
    ]
    |> List.flatten()
  end

  defp unqueued_credit_metrics do
    import Ecto.Query

    # 1h is what the monitor fails on: long enough that an incident does not
    # vanish before anyone looks, short enough that the check clears without
    # waiting a day. "all" keeps the history for context.
    since = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600, :second)

    unqueued = from(e in Lei.CreditEntry, where: e.reason == "adjustment:unqueued")

    {recent_entries, recent_credits} =
      count_and_sum(from(e in unqueued, where: e.inserted_at >= ^since))

    {all_entries, all_credits} = count_and_sum(unqueued)

    [
      ~s(lei_unqueued_credits{window="1h",measure="entries"} #{recent_entries}),
      ~s(lei_unqueued_credits{window="1h",measure="credits"} #{recent_credits}),
      ~s(lei_unqueued_credits{window="all",measure="entries"} #{all_entries}),
      ~s(lei_unqueued_credits{window="all",measure="credits"} #{all_credits})
    ]
  rescue
    error ->
      require Logger
      Logger.error("Unqueued credit metrics failed: #{inspect(error)}")
      [~s(lei_unqueued_credits{window="1h",measure="error"} 1)]
  end

  defp count_and_sum(query) do
    import Ecto.Query

    {entries, credits} =
      query
      |> select([e], {count(e.id), sum(e.delta)})
      |> Lei.Repo.one()

    {entries || 0, abs(to_int(credits))}
  end

  defp unbilled_pro_metrics do
    counts = Lei.UsageTracker.unbilled_pro_counts()

    [
      ~s(lei_unbilled_pro_orgs{state="no_customer"} #{counts.no_customer}),
      ~s(lei_unbilled_pro_orgs{state="no_subscription"} #{counts.no_subscription})
    ]
  rescue
    error ->
      require Logger
      Logger.error("Unbilled pro metrics failed: #{inspect(error)}")
      [~s(lei_unbilled_pro_orgs{state="error"} 1)]
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

  defp reversal_metrics do
    import Ecto.Query

    totals =
      from(e in Lei.CreditEntry,
        where: like(e.reason, "reversal:%") or like(e.reason, "reinstatement:%"),
        group_by: [e.reason, fragment("?->>'kind'", e.metadata)],
        select: {e.reason, fragment("?->>'kind'", e.metadata), count(e.id), sum(e.delta)}
      )
      |> Lei.Repo.all()
      |> Map.new(fn {reason, kind, entries, delta} ->
        [_, rail] = String.split(reason, ":", parts: 2)
        {{rail, kind || "manual"}, {entries, abs(to_int(delta))}}
      end)

    defaults =
      for rail <- Lei.Payments.known_rails(),
          kind <- ~w(refund dispute reinstatement),
          into: %{},
          do: {{rail, kind}, {0, 0}}

    defaults
    |> Map.merge(totals)
    |> Enum.sort()
    |> Enum.flat_map(fn {{rail, kind}, {entries, credits}} ->
      labels = ~s(rail="#{rail}",kind="#{kind}")

      [
        ~s(lei_credit_reversals{#{labels},measure="entries"} #{entries}),
        ~s(lei_credit_reversals{#{labels},measure="credits"} #{credits})
      ]
    end)
  rescue
    error ->
      require Logger
      Logger.error("Reversal metrics failed: #{inspect(error)}")
      [~s(lei_credit_reversals{measure="error"} 1)]
  end

  defp switch_metrics do
    Enum.map(Lei.Payments.Switches.state() |> Enum.sort(), fn {path, s} ->
      ~s(lei_payment_switch_enabled{path="#{path}"} #{if s.enabled, do: 1, else: 0})
    end)
  rescue
    error ->
      require Logger
      Logger.error("Payment switch metrics failed: #{inspect(error)}")
      [~s(lei_payment_switch_enabled{measure="error"} 1)]
  end

  defp held_metrics do
    counts = Lei.Payments.Held.counts()

    defaults =
      for rail <- Application.get_env(:lei_service, :payment_rails, []),
          Lei.Payments.MachineRail.funds_move_before_settlement?(rail),
          into: %{},
          do: {rail.name(), 0}

    defaults
    |> Map.merge(counts)
    |> Enum.sort()
    |> Enum.map(fn {rail, n} -> ~s(lei_payment_held{rail="#{rail}"} #{n}) end)
  rescue
    error ->
      require Logger
      Logger.error("Held payment metrics failed: #{inspect(error)}")
      [~s(lei_payment_held{measure="error"} 1)]
  end

  defp stripe_reconciliation_metrics do
    case Lei.StripeReconciliation.latest() do
      nil ->
        [~s(lei_stripe_reconciliation{measure="runs"} 0)]

      run ->
        age =
          NaiveDateTime.diff(NaiveDateTime.utc_now(), run.inserted_at, :second)

        base = [
          ~s(lei_stripe_reconciliation{measure="runs"} #{Lei.StripeReconciliation.count()}),
          ~s(lei_stripe_reconciliation{measure="age_seconds"} #{max(age, 0)}),
          ~s(lei_stripe_reconciliation{measure="failed"} #{if run.status == "failed", do: 1, else: 0})
        ]

        if run.status == "failed" do
          base
        else
          base ++
            [
              ~s(lei_stripe_reconciliation{measure="discrepancies"} #{run.discrepancy_count}),
              ~s(lei_stripe_reconciliation{measure="ledger_purchases"} #{run.ledger_purchases}),
              ~s(lei_stripe_reconciliation{measure="stripe_purchases"} #{run.stripe_purchases}),
              # Verification probes the comparison deliberately did not report.
              # Published so an exclusion that starts swallowing more than it
              # should reads as a number climbing, rather than as silence.
              ~s(lei_stripe_reconciliation{measure="probe_excluded"} #{run.probe_excluded || 0})
            ]
        end
    end
  rescue
    error ->
      require Logger
      Logger.error("Stripe reconciliation metrics failed: #{inspect(error)}")
      [~s(lei_stripe_reconciliation{measure="error"} 1)]
  end

  defp payment_outcome_metrics do
    counts =
      Map.new(Lei.Payments.Outcomes.summary(), fn row ->
        {{row.rail, row.outcome, row.reason}, row.count}
      end)

    # Every configured rail's main outcomes at zero, so "none in 24 hours"
    # reads differently from "not collected".
    defaults =
      for rail <- Application.get_env(:lei_service, :payment_rails, []),
          outcome <- ~w(issued presented settled refused),
          into: %{},
          do: {{rail.name(), outcome, ""}, 0}

    defaults
    |> Map.merge(counts)
    |> Enum.sort()
    |> Enum.map(fn {{rail, outcome, reason}, count} ->
      ~s(lei_payment_outcomes{rail="#{rail}",outcome="#{outcome}",reason="#{reason}",window="24h"} #{count})
    end)
  rescue
    error ->
      require Logger
      Logger.error("Payment outcome metrics failed: #{inspect(error)}")
      [~s(lei_payment_outcomes{measure="error"} 1)]
  end

  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(n) when is_integer(n), do: n
  defp to_int(nil), do: 0

  defp reversal_event_metrics do
    stats = Lei.ReversalStats.all()

    Enum.map(Lei.ReversalStats.outcomes(), fn outcome ->
      ~s(lei_stripe_reversal_events_total{result="#{outcome}"} #{Map.get(stats, outcome, 0)})
    end)
  end

  defp webhook_metrics do
    stats = Lei.WebhookStats.all()

    Enum.map(Lei.WebhookStats.outcomes(), fn outcome ->
      "lei_stripe_webhook_total{result=\"#{outcome}\"} #{Map.get(stats, outcome, 0)}"
    end)
  end

  defp metering_metrics do
    report = Lei.Reconciliation.stripe_reporting()

    [
      "lei_stripe_metering{measure=\"reported\"} #{report.reported}",
      "lei_stripe_metering{measure=\"failed\"} #{report.failed}",
      "lei_stripe_metering{measure=\"unreported\"} #{report.unreported}",
      "lei_stripe_metering{measure=\"unreported_credits\"} #{report.unreported_credits}",
      "lei_stripe_metering{measure=\"metered_orgs\"} #{report.metered_orgs}"
    ]
  rescue
    error ->
      require Logger
      Logger.error("Metering metrics failed: #{inspect(error)}")
      ["lei_stripe_metering{measure=\"error\"} 1"]
  end

  defp format_ecosystem_metrics(ecosystems) when map_size(ecosystems) == 0, do: []

  defp format_ecosystem_metrics(ecosystems) do
    Enum.map(ecosystems, fn {ecosystem, count} ->
      "lei_cache_ecosystems{ecosystem=\"#{ecosystem}\"} #{count}"
    end)
  end

  # Metrics from apps this library cannot depend on -- the web app's Redis-backed
  # trending job, for one (#158). Registered as `{module, function, args}` under
  # `:metrics_collectors`, returning lines. A collector whose module is not
  # loaded is skipped; one that raises reports that it failed rather than
  # taking /metrics down with it.
  defp registered_metrics do
    :lei_service
    |> Application.get_env(:metrics_collectors, [])
    |> Enum.flat_map(fn {module, function, args} ->
      if Code.ensure_loaded?(module) do
        try do
          ["" | apply(module, function, args)]
        rescue
          _ -> ["", ~s(lei_metrics_collector_error{collector="#{inspect(module)}"} 1)]
        end
      else
        []
      end
    end)
  end
end
