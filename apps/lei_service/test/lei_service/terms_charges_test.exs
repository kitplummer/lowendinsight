defmodule LeiService.TermsChargesTest do
  @moduledoc """
  What `/terms` says is charged, and how to get money back.

  During beta the page said "Nothing is charged today" while the gate asked
  every account-less agent for $0.50 (ADR-007). On testnet that is only
  misleading; the moment the Stripe key is live it is false, and it was the
  page a buyer would read to find out what they paid for (lei_ops#1).

  Asserted against the rendered page in each Stripe mode, because the page is
  generated from the running deployment and has to be right in all of them.
  """
  use ExUnit.Case, async: false

  @opts LeiService.Endpoint.init([])

  setup do
    saved =
      for key <- [:billing_mode, :stripe_secret_key, :beta_top_up_credits],
          do: {key, Application.get_env(:lei_service, key)}

    on_exit(fn ->
      for {key, value} <- saved do
        if is_nil(value),
          do: Application.delete_env(:lei_service, key),
          else: Application.put_env(:lei_service, key, value)
      end
    end)

    Application.put_env(:lei_service, :billing_mode, :beta)
    :ok
  end

  defp stripe_key!(prefix),
    do: Application.put_env(:lei_service, :stripe_secret_key, prefix <> String.duplicate("a", 24))

  defp terms do
    conn = :get |> Plug.Test.conn("/terms") |> LeiService.Endpoint.call(@opts)
    assert conn.status == 200
    conn.resp_body
  end

  describe "during beta" do
    test "it states the account charge instead of saying nothing is charged" do
      stripe_key!("sk_test_")
      body = terms()

      refute body =~ "Nothing is charged today",
             "the terms say nothing is charged while the gate asks agents for $0.50"

      assert body =~ "500 credits ($0.50)",
             "the terms do not say what an account-less agent is asked for"

      assert body =~ "buys an account, not analysis"
    end

    test "the amount follows the gate, not a constant" do
      stripe_key!("sk_test_")
      Application.put_env(:lei_service, :beta_top_up_credits, 1_000)

      assert terms() =~ "1,000 credits ($1.00)",
             "the terms quote an amount the gate no longer asks for"
    end

    test "on testnet it says no real money moves" do
      stripe_key!("sk_test_")
      body = terms()

      assert body =~ "test token"
      refute body =~ "USDC.e"
    end

    test "with a live key it says the payment is real" do
      stripe_key!("sk_live_")
      body = terms()

      assert body =~ "USDC.e"

      refute body =~ "test token",
             "the terms tell a buyer paying real money that it is a test token"
    end
  end

  describe "refunds" do
    test "the page says how to get money back, in either billing mode" do
      for mode <- [:beta, :charge] do
        Application.put_env(:lei_service, :billing_mode, mode)
        body = terms()

        assert body =~ "Refunds", "#{mode}: no refund section"
        assert body =~ "within 30 days", "#{mode}: no refund window"

        assert body =~ "the wallet or card that paid",
               "#{mode}: no statement of where a refund goes"
      end
    end
  end
end
