defmodule Lei.BillingReporter do
  @moduledoc """
  GenServer that periodically reports metered usage to Stripe
  for pro-tier orgs with overage beyond their included credit.

  Runs daily. For each pro org with a stripe_metered_subscription_item_id:
  1. Gets current period usage
  2. Subtracts included credit ($15 for Pro tier)
  3. Reports overage to Stripe if positive
  """
  use GenServer
  require Logger
  import Ecto.Query
  alias Lei.{Repo, Org, UsageTracker}

  @default_interval_ms :timer.hours(24)

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Trigger an immediate billing report run."
  def report_now(server \\ __MODULE__) do
    GenServer.call(server, :report_now, 30_000)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)

    if Keyword.get(opts, :start_timer, true) do
      Process.send_after(self(), :tick, interval)
    end

    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_call(:report_now, _from, state) do
    result = run_billing_report()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run_billing_report()
    Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  # --- Core logic ---

  @doc "Run billing report for all pro orgs with metered subscriptions."
  def run_billing_report do
    orgs =
      Repo.all(
        from(o in Org,
          where:
            o.tier == "pro" and
              o.status == "active" and
              not is_nil(o.stripe_metered_subscription_item_id)
        )
      )

    results =
      Enum.map(orgs, fn org ->
        case report_for_org(org) do
          {:ok, result} ->
            Logger.info("Billing reported for org #{org.id}: #{inspect(result)}")
            {:ok, org.id, result}

          {:error, reason} ->
            Logger.warning("Billing report failed for org #{org.id}: #{inspect(reason)}")
            {:error, org.id, reason}
        end
      end)

    {:ok, results}
  end

  @doc "Report usage for a single org. Returns {:ok, :no_overage} or {:ok, map} or {:error, reason}."
  def report_for_org(%Org{} = org) do
    usage = UsageTracker.get_current_usage(org.id)
    pro_credit = pro_tier_credit_cents()
    overage = Decimal.sub(usage.total_cost_cents, Decimal.new("#{pro_credit}"))

    if Decimal.compare(overage, Decimal.new(0)) == :gt do
      # Report overage to Stripe as integer cents (rounded up)
      overage_int = overage |> Decimal.round(0, :up) |> Decimal.to_integer()
      timestamp = System.system_time(:second)
      stripe = Lei.Stripe.impl()

      case stripe.report_usage(org.stripe_metered_subscription_item_id, overage_int, timestamp) do
        {:ok, record} ->
          {:ok, %{overage_cents: overage_int, stripe_record: record}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, :no_overage}
    end
  end

  defp pro_tier_credit_cents do
    Application.get_env(:lowendinsight, :pro_tier_credit_cents, 1500)
  end
end
