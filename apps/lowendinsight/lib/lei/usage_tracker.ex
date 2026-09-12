defmodule Lei.UsageTracker do
  @moduledoc """
  Tracks analysis usage per org and billing period.

  Rates from ADR-001:
  - Cache hit:  $0.005 (0.5 cents)
  - Cache miss: $0.05  (5.0 cents)
  """

  import Ecto.Query
  require Logger
  alias Lei.{Repo, Org, AnalysisUsage, Credits}

  @default_hit_cost_cents 0.5
  @default_miss_cost_cents 5.0
  @default_free_tier_limit 200

  @doc """
  Record usage for an org in the current billing period.
  Upserts the analysis_usage row, incrementing hit/miss counts and cost.
  """
  def record_usage(org_id, api_key_id, cache_hits, cache_misses) do
    period_start = current_period_start()
    cost = calculate_cost(cache_hits, cache_misses)

    # The usage row and the ledger debit are one transaction. Both are local
    # writes describing the same event, so there is no state in which one is
    # correct without the other -- a committed usage row with no debit is an
    # analysis delivered and not accounted for, and a debit with no usage row
    # is a charge for nothing.
    #
    # Reconciliation (#105) then guards against drift from other causes, rather
    # than against a gap this function creates on every failure.
    result =
      Repo.transaction(fn ->
        with {:ok, usage} <-
               upsert_usage(org_id, api_key_id, period_start, cache_hits, cache_misses, cost),
             :ok <- debit_credits(usage, cache_hits, cache_misses) do
          usage
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # Stripe is reported only once the transaction has committed, and never
    # from inside it. Two reasons: an HTTP call holds a database connection open
    # for its whole duration, and reporting from inside a transaction that later
    # rolls back bills a customer for usage this database has no record of --
    # the fault fixed in #96.
    with {:ok, usage} <- result do
      report_meter_event(org_id, cost, usage)
    end

    result
  end

  defp upsert_usage(org_id, api_key_id, period_start, cache_hits, cache_misses, cost) do
    case Repo.one(
           from(u in AnalysisUsage,
             where: u.org_id == ^org_id and u.period_start == ^period_start
           )
         ) do
      nil ->
        %AnalysisUsage{}
        |> AnalysisUsage.changeset(%{
          org_id: org_id,
          api_key_id: api_key_id,
          period_start: period_start,
          cache_hits: cache_hits,
          cache_misses: cache_misses,
          total_cost_cents: cost
        })
        |> Repo.insert()

      existing ->
        existing
        |> AnalysisUsage.changeset(%{
          cache_hits: existing.cache_hits + cache_hits,
          cache_misses: existing.cache_misses + cache_misses,
          total_cost_cents: Decimal.add(existing.total_cost_cents, cost)
        })
        |> Repo.update()
    end
  end

  @doc """
  Get the current billing period's usage for an org.
  Returns a map with hits, misses, and total_cost_cents.
  """
  def get_current_usage(org_id) do
    period_start = current_period_start()

    case Repo.one(
           from(u in AnalysisUsage,
             where: u.org_id == ^org_id and u.period_start == ^period_start
           )
         ) do
      nil ->
        %{
          period_start: period_start,
          cache_hits: 0,
          cache_misses: 0,
          total_cost_cents: Decimal.new(0)
        }

      usage ->
        %{
          period_start: usage.period_start,
          cache_hits: usage.cache_hits,
          cache_misses: usage.cache_misses,
          total_cost_cents: usage.total_cost_cents
        }
    end
  end

  @doc """
  Check whether a free-tier org has remaining quota.
  Returns {:ok, remaining} or {:error, :quota_exceeded}.
  """
  def check_free_tier_quota(org_id) do
    case Repo.get(Org, org_id) do
      nil ->
        {:error, :org_not_found}

      # A wallet-identified org has no free allowance at all -- ADR-002, and the
      # reason is that a wallet costs nothing to create, so any per-wallet
      # allowance is a per-attacker allowance. Access is the credit balance and
      # nothing else, checked before the work rather than after it.
      %Org{wallet_address: wallet} = org when is_binary(wallet) and wallet != "" ->
        check_credit_balance(org)

      %Org{tier: "pro"} ->
        {:ok, :unlimited}

      %Org{tier: "free"} = org ->
        usage = get_current_usage(org_id)
        total_analyses = usage.cache_hits + usage.cache_misses
        limit = org.free_tier_analyses_limit || free_tier_limit()

        if total_analyses >= limit do
          {:error, :quota_exceeded, %{used: total_analyses, limit: limit}}
        else
          {:ok, limit - total_analyses}
        end
    end
  end

  # Credits are the whole gate for a wallet org. A zero or negative balance is
  # refused here, before the analysis runs -- ADR-002 allows a balance to go
  # negative because refusing after the work is done loses the record rather
  # than preventing the cost, so the refusal has to happen at this point.
  defp check_credit_balance(%Org{id: org_id}) do
    case Lei.Credits.balance(org_id) do
      balance when balance > 0 ->
        {:ok, balance}

      balance ->
        {:error, :insufficient_credits, %{balance: balance}}
    end
  end

  @doc """
  Pure function: calculate cost in cents given hit/miss counts.
  Uses ADR-001 rates: $0.005/hit, $0.05/miss.
  """
  def calculate_cost(cache_hits, cache_misses) do
    hit_rate = hit_cost_cents()
    miss_rate = miss_cost_cents()

    hit_cost = Decimal.mult(Decimal.new("#{hit_rate}"), Decimal.new(cache_hits))
    miss_cost = Decimal.mult(Decimal.new("#{miss_rate}"), Decimal.new(cache_misses))
    Decimal.add(hit_cost, miss_cost)
  end

  @doc """
  Record usage asynchronously (fire-and-forget), matching the pattern
  used by Lei.ApiKeys.touch_last_used/1.
  """
  def record_usage_async(org_id, api_key_id, cache_hits, cache_misses) do
    Task.start(fn ->
      record_usage(org_id, api_key_id, cache_hits, cache_misses)
    end)
  end

  @doc "Returns the first day of the current month as the billing period start."
  def current_period_start do
    today = Date.utc_today()
    Date.new!(today.year, today.month, 1)
  end

  defp hit_cost_cents do
    Application.get_env(:lowendinsight, :cache_hit_cost_cents, @default_hit_cost_cents)
  end

  defp miss_cost_cents do
    Application.get_env(:lowendinsight, :cache_miss_cost_cents, @default_miss_cost_cents)
  end

  defp free_tier_limit do
    Application.get_env(:lowendinsight, :free_tier_monthly_limit, @default_free_tier_limit)
  end

  # Records what this analysis consumed against the org's credit balance.
  #
  # Returns {:error, reason} rather than logging and continuing. The caller runs
  # this inside the same transaction as the usage row, so a failure here rolls
  # both back: the alternative is a usage row with no matching debit, which is
  # drift that has to be found later rather than a failure handled now.
  #
  # The balance is allowed to go negative. Refusal belongs before the work, not
  # after it -- see ADR-002.
  defp debit_credits(%AnalysisUsage{} = usage, cache_hits, cache_misses) do
    credits = Credits.cost_in_credits(cache_hits, cache_misses)

    if credits > 0 do
      case Credits.debit(usage.org_id, credits, debit_reason(),
             external_ref: debit_ref(usage),
             metadata: %{
               "analysis_usage_id" => usage.id,
               "cache_hits" => cache_hits,
               "cache_misses" => cache_misses,
               "period_start" => Date.to_iso8601(usage.period_start)
             }
           ) do
        {:ok, _entry} ->
          :ok

        {:error, :duplicate} ->
          # This exact state of the usage row was already debited. Expected on a
          # retry of the ledger write, and not a reason to roll back the usage
          # row that produced it.
          :ok

        {:error, reason} ->
          Logger.error(
            "Credit debit failed for org #{usage.org_id}: #{inspect(reason)}. " <>
              "Rolling back #{credits} credits of usage rather than recording it unbilled."
          )

          {:error, reason}
      end
    else
      :ok
    end
  end

  # A seam so the rollback path is reachable from a test. Nothing in production
  # sets it; an invalid reason fails Lei.CreditEntry's changeset, which is the
  # closest reachable stand-in for a database error mid-transaction.
  defp debit_reason do
    Application.get_env(:lowendinsight, :credit_debit_reason, "debit:analysis")
  end

  # The usage row's cumulative counters after the update. They only ever
  # increase, so each committed increment yields a distinct reference, and
  # re-deriving it from an unchanged row yields the same one.
  #
  # This makes the ledger write idempotent with respect to itself. It does not
  # deduplicate analyses -- a genuinely repeated request increments
  # analysis_usage again and is debited again, which is correct, because it was
  # served again.
  defp debit_ref(%AnalysisUsage{} = usage) do
    "analysis-#{usage.id}-#{usage.cache_hits}-#{usage.cache_misses}"
  end

  # Reports this usage to Stripe as a billing meter event.
  #
  # Meter events are additive, so this sends the cost of *this* usage only --
  # never a running total. The included Pro credit is expressed as a graduated
  # tier on the Stripe price (first N units at zero), not computed here: making
  # Stripe the single place the credit is applied removes the double-counting
  # that cumulative reporting invites.
  #
  # Free-tier orgs have no Stripe customer and are skipped. Failures are logged
  # and swallowed: a metering outage must not fail an analysis the user has
  # already been served.
  defp report_meter_event(org_id, cost_cents, usage) do
    case Repo.get(Org, org_id) do
      %Org{tier: "pro", stripe_customer_id: customer_id} when is_binary(customer_id) ->
        units = to_meter_units(cost_cents)

        if units > 0 do
          stripe = Lei.Stripe.impl()
          identifier = meter_event_identifier(usage, units)

          case stripe.report_meter_event(
                 customer_id,
                 units,
                 System.system_time(:second),
                 identifier
               ) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("Stripe meter event failed for org #{org_id}: #{inspect(reason)}")
              :error
          end
        else
          :ok
        end

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning("Stripe meter event raised for org #{org_id}: #{inspect(error)}")
      :error
  end

  # The meter's unit is a tenth of a cent, so every ADR-001 rate is an integer:
  # a cache hit ($0.005) is 5 units, a miss ($0.05) is 50.
  defp to_meter_units(cost_cents) do
    cost_cents
    |> Decimal.mult(10)
    |> Decimal.round(0, :up)
    |> Decimal.to_integer()
  end

  # Stripe deduplicates on this, so a retry of the same usage is a no-op rather
  # than a second charge. Derived from the committed row's id and updated_at,
  # which together change exactly when new usage is recorded -- so a retry of
  # the *same* write reuses the key, while genuinely new usage gets a new one.
  defp meter_event_identifier(%AnalysisUsage{id: id, updated_at: updated_at}, units) do
    stamp = updated_at |> NaiveDateTime.to_iso8601() |> String.replace(~r/[^0-9]/, "")
    "lei-usage-#{id}-#{stamp}-#{units}"
  end
end
