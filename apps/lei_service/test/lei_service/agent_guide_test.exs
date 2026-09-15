defmodule LeiService.AgentGuideTest do
  @moduledoc """
  The homepage and /llms.txt tell consumers how to pay and what is kept. Every
  claim comes from the running configuration, so these assert that changing
  the thing described changes what the page says -- a hardcoded price or an
  "available" that is not would pass a test that only looked for the words.
  """
  use ExUnit.Case, async: false

  import Mox
  import Plug.Test

  alias LeiService.AgentGuide

  @opts LeiService.Endpoint.init([])
  @deposit "0x5ff8d73e8bccd3701c9aef78389f3b9771172b5c"

  setup :set_mox_global

  setup do
    keys = [
      :stripe_secret_key,
      :tempo_deposit_address,
      :cache_hit_cost_cents,
      :cache_miss_cost_cents,
      :default_top_up_credits,
      :free_tier_monthly_limit
    ]

    saved = for k <- keys, do: {k, Application.fetch_env(:lei_service, k)}

    on_exit(fn ->
      for {k, v} <- saved do
        case v do
          {:ok, value} -> Application.put_env(:lei_service, k, value)
          :error -> Application.delete_env(:lei_service, k)
        end
      end

      send(Lei.Stripe.ObjectCheck, :check)
    end)

    :ok
  end

  defp page, do: conn(:get, "/") |> LeiService.Endpoint.call(@opts)
  defp llms, do: conn(:get, "/llms.txt") |> LeiService.Endpoint.call(@opts)

  defp test_key,
    do:
      Application.put_env(
        :lei_service,
        :stripe_secret_key,
        "sk_test_" <> String.duplicate("x", 24)
      )

  defp live_key,
    do:
      Application.put_env(
        :lei_service,
        :stripe_secret_key,
        "sk_live_" <> String.duplicate("x", 24)
      )

  defp confirm_deposit_address do
    Application.put_env(:lei_service, :tempo_deposit_address, @deposit)
    stub(Lei.StripeMock, :retrieve_price, fn _ -> {:ok, %{"active" => true}} end)
    stub(Lei.StripeMock, :list_deposit_addresses, fn _ -> {:ok, [@deposit]} end)
    send(Lei.Stripe.ObjectCheck, :check)

    Enum.reduce_while(1..100, nil, fn _, _ ->
      if Lei.Stripe.ObjectCheck.deposit_address_confirmed?(@deposit),
        do: {:halt, :ok},
        else: Process.sleep(10) && {:cont, nil}
    end) || flunk("deposit address never confirmed")
  end

  describe "usd/1" do
    test "whole cents at two decimals, fractions of a cent at three" do
      assert AgentGuide.usd(15_000) == "$15.00"
      assert AgentGuide.usd(50) == "$0.05"
      # A cache hit is half a cent. "$0.01" would double the stated price.
      assert AgentGuide.usd(5) == "$0.005"
      assert AgentGuide.usd(0) == "$0.00"
    end

    test "number/1 separates thousands" do
      assert AgentGuide.number(15_000) == "15,000"
      assert AgentGuide.number(1_234_567) == "1,234,567"
      assert AgentGuide.number(500) == "500"
      assert AgentGuide.number(0) == "0"
    end
  end

  describe "prices" do
    test "come from the rates the ledger charges, on the page and in llms.txt" do
      Application.put_env(:lei_service, :cache_hit_cost_cents, 0.7)
      Application.put_env(:lei_service, :cache_miss_cost_cents, 6.0)
      Application.put_env(:lei_service, :default_top_up_credits, 20_000)
      Application.put_env(:lei_service, :free_tier_monthly_limit, 321)

      for body <- [page().resp_body, llms().resp_body] do
        assert body =~ "7 credits"
        assert body =~ "$0.007"
        assert body =~ "60 credits"
        assert body =~ "$0.06"
        assert body =~ "20,000 credits"
        assert body =~ "$20.00"
        assert body =~ "321 analyses a month"
      end
    end
  end

  describe "mode" do
    test "a test key says test mode and testnet, and makes no real-money claim" do
      test_key()

      for body <- [page().resp_body, llms().resp_body] do
        assert body =~ "test mode"
        assert body =~ "pathUSD"
        assert body =~ "Tempo testnet"
        refute body =~ "USDC.e"
      end
    end

    test "a live key says USDC.e on Tempo, and no test mode" do
      live_key()

      for body <- [page().resp_body, llms().resp_body] do
        refute body =~ "test mode"
        assert body =~ "USDC.e"
        refute body =~ "pathUSD"
      end
    end
  end

  describe "availability" do
    test "stablecoin is unavailable when the rail would issue no challenge, and the page says so" do
      test_key()
      Application.delete_env(:lei_service, :tempo_deposit_address)

      assert AgentGuide.facts().stablecoin.available? == false
      assert page().resp_body =~ "Stablecoin payment is not available right now"
      assert llms().resp_body =~ "Stablecoin payment is not available right now"
    end

    test "stablecoin is available only once Stripe has confirmed the deposit address" do
      test_key()
      confirm_deposit_address()

      assert AgentGuide.facts().stablecoin.available? == true
      refute page().resp_body =~ "not available right now"
      assert llms().resp_body =~ "MPP `tempo`** (available)"
    end
  end

  describe "for agents" do
    test "the page leads with paying, not signing up, and shows the 402" do
      body = page().resp_body

      assert body =~ ~s(id="agents")
      assert body =~ "no account needed"
      assert body =~ "402 Payment Required"
      assert body =~ "Lei-Api-Key"
      assert body =~ ~s(id="no-account")
    end

    test "the page points agents at the markdown guide" do
      assert page().resp_body =~ ~s(<link rel="alternate" type="text/markdown" href="/llms.txt")
    end

    test "llms.txt is served as markdown, unauthenticated" do
      conn = llms()

      assert conn.status == 200
      assert ["text/markdown" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      assert conn.resp_body =~ "# LowEndInsight"
      assert conn.resp_body =~ "WWW-Authenticate: Payment"
    end

    test "no example suggests analysis is free without paying or a key" do
      # The page's first example was an unauthenticated curl presented as if it
      # returned a report; since #148 it returns a 402.
      body = page().resp_body
      [_, agents_box] = String.split(body, ~s(id="agents"), parts: 2)
      [agents_box | _] = String.split(agents_box, ~s(id="pricing"), parts: 2)
      assert agents_box =~ "HTTP/2 402"
    end
  end
end
