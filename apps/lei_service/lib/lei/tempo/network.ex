defmodule Lei.Tempo.Network do
  @moduledoc """
  Which Tempo chain, token and RPC endpoint go with the Stripe mode.

  Derived from `Lei.Stripe.Mode`, never configured separately, for the reason
  that module gives: a sandbox Stripe key verifies testnet transfers, a live key
  verifies mainnet ones, and a setting beside the key is a setting that can
  disagree with it. Values are those the reference server (mppx) uses.
  """

  # TIP-20 tokens on Tempo all use 6 decimals.
  @decimals 6

  @networks %{
    live: %{
      chain_id: 4217,
      # USDC.e
      token: "0x20c000000000000000000000b9537d11c60e8b50",
      rpc_url: "https://rpc.tempo.xyz"
    },
    test: %{
      chain_id: 42431,
      # pathUSD, what Stripe sandbox accepts on testnet (observed, #144)
      token: "0x20c0000000000000000000000000000000000000",
      rpc_url: "https://rpc.moderato.tempo.xyz"
    }
  }

  def decimals, do: @decimals

  @doc "The network for a mode, or `nil` when Stripe is not configured."
  def for_mode(mode) when mode in [:live, :test] do
    network = Map.fetch!(@networks, mode)

    Map.put(
      network,
      :rpc_url,
      Application.get_env(:lei_service, :tempo_rpc_url, network.rpc_url)
    )
  end

  def for_mode(_), do: nil

  def current, do: for_mode(Lei.Stripe.Mode.current())
end
