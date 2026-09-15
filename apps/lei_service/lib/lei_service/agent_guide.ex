defmodule LeiService.AgentGuide do
  @moduledoc """
  What the homepage and `/llms.txt` tell a consumer: prices, how to pay, what
  is kept. Derived from the running configuration, never written into a
  template.

  A page that says "pay with USDC" while stablecoin is unconfigured, or quotes
  a price the ledger no longer charges, is this codebase's usual failure in
  prose -- reporting something works while it does not. So each claim comes
  from the thing it describes: prices from the rates the ledger debits,
  availability from whether the rail would issue a challenge right now, and
  the network from the Stripe key's mode.
  """

  alias Lei.Payments.Rails.{Mpp, Tempo}

  # One credit is $0.001 (ADR-002), so a rate in cents is a tenth of its credits.
  @credits_per_cent 10

  # Shown on /signup; not held in config.
  @pro_price "$29/month"

  def facts do
    mode = Lei.Stripe.Mode.current()
    top_up = Application.get_env(:lowendinsight, :default_top_up_credits, 15_000)
    hit = credits(:cache_hit_cost_cents, 0.5)
    miss = credits(:cache_miss_cost_cents, 5.0)

    %{
      mode: mode,
      live?: mode == :live,
      hit_credits: hit,
      hit_usd: usd(hit),
      miss_credits: miss,
      miss_usd: usd(miss),
      top_up_credits: top_up,
      top_up_usd: usd(top_up),
      free_monthly_analyses: Application.get_env(:lowendinsight, :free_tier_monthly_limit, 200),
      pro_price: @pro_price,
      pro_included_usd:
        usd(
          round(
            Application.get_env(:lowendinsight, :pro_tier_credit_cents, 1500.0) *
              @credits_per_cent
          )
        ),
      stablecoin: stablecoin(mode),
      card: card()
    }
  end

  defp credits(key, default) do
    round(Application.get_env(:lowendinsight, key, default) * @credits_per_cent)
  end

  @doc "An integer with thousands separators: 15000 -> \"15,000\"."
  def number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc """
  Credits as dollars. Two decimals when the amount is whole cents ("$15.00",
  "$0.05"), three when it is not ("$0.005") -- a cache hit costs half a cent,
  and rounding it to "$0.01" would double the stated price.
  """
  def usd(credits) when is_integer(credits) and credits >= 0 do
    whole = div(credits, 1000)
    frac = rem(credits, 1000)

    if rem(frac, 10) == 0 do
      "$#{whole}.#{frac |> div(10) |> Integer.to_string() |> String.pad_leading(2, "0")}"
    else
      "$#{whole}.#{frac |> Integer.to_string() |> String.pad_leading(3, "0")}"
    end
  end

  # Available exactly when the rail would issue a challenge to an agent with
  # no org -- the same check, not a second opinion about it.
  defp stablecoin(mode) do
    network =
      case mode do
        :live -> %{chain: "Tempo", token: "USDC.e", real_money?: true}
        _ -> %{chain: "Tempo testnet", token: "pathUSD", real_money?: false}
      end

    Map.put(
      network,
      :available?,
      match?({:ok, _}, safe(fn -> Tempo.requirements(Tempo.minimum_purchase_credits()) end))
    )
  end

  defp card do
    %{available?: match?({:ok, _}, safe(fn -> Mpp.requirements(15_000) end))}
  end

  # Rendering the homepage must not depend on a payment rail being healthy.
  defp safe(fun) do
    fun.()
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end
end
