defmodule Lei.UsageTracker do
  @moduledoc """
  Tracks analysis usage per org and billing period.

  Rates from ADR-001:
  - Cache hit:  $0.005 (0.5 cents)
  - Cache miss: $0.05  (5.0 cents)
  """

  import Ecto.Query
  require Logger
  alias Lei.{Repo, Org, AnalysisUsage}

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
    report_meter_event(org_id, cost)

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
  defp report_meter_event(org_id, cost_cents) do
    case Repo.get(Org, org_id) do
      %Org{tier: "pro", stripe_customer_id: customer_id} when is_binary(customer_id) ->
        units = to_meter_units(cost_cents)

        if units > 0 do
          stripe = Lei.Stripe.impl()

          case stripe.report_meter_event(customer_id, units, System.system_time(:second)) do
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
end
