defmodule Lei.Payments.ReversalsTest do
  @moduledoc """
  Money that goes back to a customer comes out of the ledger by itself (#208).

  Before this, `Lei.StripeWebhookHandler` ignored every refund and dispute
  event, and `Lei.Payments.reverse_settlement/2` had no caller: a refund made in
  the Stripe Dashboard left the credits it paid for spendable, and the ledger
  disagreed with Stripe's balance with nothing to show for it.

  The payloads below follow real sandbox events captured on 2026-09-16
  (`charge.refunded` at 500 then 1500 cents on one charge;
  `charge.dispute.funds_withdrawn` and `charge.dispute.funds_reinstated` on a
  dispute won with `winning_evidence`), trimmed to the fields Stripe sends that
  the handler reads.

  Deliveries go through `Lei.Web.Router` signed, as Stripe sends them.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn
  import Mox

  alias Lei.{Credits, Payments, Repo, Wallets}

  @secret "whsec_test_secret_for_reversals"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    stub(Lei.StripeMock, :construct_webhook_event, fn payload, signature, secret ->
      Lei.Stripe.construct_webhook_event(payload, signature, secret)
    end)

    original = Application.get_env(:lei_service, :stripe_webhook_secret)
    Application.put_env(:lei_service, :stripe_webhook_secret, @secret)
    Lei.ReversalStats.reset()

    on_exit(fn ->
      if original,
        do: Application.put_env(:lei_service, :stripe_webhook_secret, original),
        else: Application.delete_env(:lei_service, :stripe_webhook_secret)
    end)

    :ok
  end

  defp deliver(event) do
    body = Poison.encode!(event)
    ts = System.system_time(:second)
    sig = :crypto.mac(:hmac, :sha256, @secret, "#{ts}.#{body}") |> Base.encode16(case: :lower)

    conn(:post, "/webhooks/stripe", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("stripe-signature", "t=#{ts},v1=#{sig}")
    |> put_private(:raw_body, body)
    |> Lei.Web.Router.call(Lei.Web.Router.init([]))
  end

  defp event(type, object, id \\ nil) do
    %{
      "id" => id || "evt_#{System.unique_integer([:positive])}",
      "object" => "event",
      "type" => type,
      "livemode" => false,
      "data" => %{"object" => object}
    }
  end

  defp pi_id, do: "pi_#{System.unique_integer([:positive])}"

  defp wallet_org do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)
    org
  end

  # A $15 block, as each rail records it: 15,000 credits, 1,500 cents.
  defp purchase(org, rail, pi, credits \\ 15_000, cents \\ 1_500)

  defp purchase(org, :acp, pi, credits, cents) do
    # Lei.Acp grants directly, under its own prefix.
    {:ok, _} =
      Credits.grant(org.id, credits, "purchase:stripe",
        external_ref: "acp:" <> pi,
        usd_value_cents: cents
      )

    pi
  end

  defp purchase(org, rail, pi, credits, cents) do
    {:ok, _} =
      Payments.credit_settlement(org.id, %{
        credits: credits,
        rail: to_string(rail),
        settlement_ref: pi,
        usd_value_cents: cents
      })

    pi
  end

  defp charge(pi, amount_refunded, amount \\ 1_500) do
    %{
      "id" => "ch_" <> String.replace_prefix(pi, "pi_", ""),
      "object" => "charge",
      "amount" => amount,
      "amount_captured" => amount,
      "amount_refunded" => amount_refunded,
      "currency" => "usd",
      "payment_intent" => pi,
      "refunded" => amount_refunded == amount,
      "status" => "succeeded",
      "livemode" => false
    }
  end

  defp dispute(pi, amount \\ 1_500, id \\ nil) do
    %{
      "id" => id || "du_#{System.unique_integer([:positive])}",
      "object" => "dispute",
      "amount" => amount,
      "charge" => "ch_" <> String.replace_prefix(pi, "pi_", ""),
      "currency" => "usd",
      "payment_intent" => pi,
      "reason" => "fraudulent",
      "status" => "needs_response",
      "livemode" => false
    }
  end

  defp reversals(org) do
    org.id
    |> Credits.entries(limit: 100)
    |> Enum.filter(
      &(String.starts_with?(&1.reason, "reversal:") or
          String.starts_with?(&1.reason, "reinstatement:"))
    )
  end

  describe "a refund" do
    for rail <- [:tempo, :mpp] do
      test "in full, on the #{rail} rail, takes back exactly what was granted" do
        org = wallet_org()
        pi = purchase(org, unquote(rail), pi_id())

        assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200

        assert [entry] = reversals(org)
        assert entry.reason == "reversal:#{unquote(rail)}"
        assert entry.delta == -15_000
        assert entry.metadata["reverses"] == pi
        assert entry.metadata["kind"] == "refund"
        assert Credits.balance(org.id) == 0
      end
    end

    test "in full, of an ACP purchase, is a stripe-rail reversal" do
      org = wallet_org()
      pi = purchase(org, :acp, pi_id())

      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200

      assert [%{reason: "reversal:stripe", delta: -15_000}] = reversals(org)
    end

    test "in parts takes back each part, and the parts add up to the purchase" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())

      # Stripe's charge.refunded carries the cumulative amount_refunded.
      assert deliver(event("charge.refunded", charge(pi, 500))).status == 200
      assert Credits.balance(org.id) == 10_000

      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200
      assert Credits.balance(org.id) == 0
      assert reversals(org) |> Enum.map(& &1.delta) |> Enum.sort() == [-10_000, -5_000]
    end

    test "delivered out of order takes back the purchase once, not one and a third times" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())

      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200
      assert deliver(event("charge.refunded", charge(pi, 500))).status == 200

      assert Credits.balance(org.id) == 0
      assert [%{delta: -15_000}] = reversals(org)
    end

    test "redelivered under the same event id is applied once" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())
      refund = event("charge.refunded", charge(pi, 1_500))

      assert deliver(refund).status == 200
      assert deliver(refund).status == 200

      assert [_] = reversals(org)
    end

    test "described again by a different event is applied once, and still answers 200" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())

      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200
      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200

      assert [_] = reversals(org)
    end

    test "after the credits were spent takes the balance negative rather than losing the debt" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())
      {:ok, _} = Credits.debit(org.id, 12_000, "debit:analysis")

      assert deliver(event("charge.refunded", charge(pi, 1_500))).status == 200

      assert Credits.balance(org.id) == -12_000
    end

    test "for a payment the ledger never credited changes nothing, and is counted as unmatched" do
      org = wallet_org()
      _ = purchase(org, :tempo, pi_id())

      # A Pro subscription's invoice, or anything else not bought as credits.
      assert deliver(event("charge.refunded", charge(pi_id(), 2_900, 2_900))).status == 200

      assert reversals(org) == []
      assert Credits.balance(org.id) == 15_000
      assert Lei.ReversalStats.count(:unmatched) == 1
    end
  end

  describe "a dispute" do
    test "takes the credits back when Stripe withdraws the funds" do
      org = wallet_org()
      pi = purchase(org, :mpp, pi_id())

      assert deliver(event("charge.dispute.funds_withdrawn", dispute(pi))).status == 200

      assert [%{reason: "reversal:mpp", delta: -15_000} = entry] = reversals(org)
      assert entry.metadata["kind"] == "dispute"
      assert Credits.balance(org.id) == 0
    end

    test "that is opened but has not withdrawn funds changes nothing" do
      org = wallet_org()
      pi = purchase(org, :mpp, pi_id())

      assert deliver(event("charge.dispute.created", dispute(pi))).status == 200

      assert reversals(org) == []
    end

    test "won gives the credits back, leaving the balance where it started" do
      org = wallet_org()
      pi = purchase(org, :mpp, pi_id())
      du = dispute(pi)

      assert deliver(event("charge.dispute.funds_withdrawn", du)).status == 200

      assert deliver(event("charge.dispute.funds_reinstated", %{du | "status" => "won"})).status ==
               200

      assert Credits.balance(org.id) == 15_000

      assert Enum.map(reversals(org), & &1.reason) |> Enum.sort() == [
               "reinstatement:mpp",
               "reversal:mpp"
             ]
    end

    test "reinstated twice, by two events, gives the credits back once" do
      org = wallet_org()
      pi = purchase(org, :mpp, pi_id())
      du = dispute(pi)

      deliver(event("charge.dispute.funds_withdrawn", du))
      assert deliver(event("charge.dispute.funds_reinstated", du)).status == 200
      assert deliver(event("charge.dispute.funds_reinstated", du)).status == 200

      assert Credits.balance(org.id) == 15_000
    end

    test "reinstated without a withdrawal gives nothing" do
      org = wallet_org()
      pi = purchase(org, :mpp, pi_id())

      assert deliver(event("charge.dispute.funds_reinstated", dispute(pi))).status == 200

      assert Credits.balance(org.id) == 15_000
      assert reversals(org) == []
    end
  end

  describe "refunds and disputes together" do
    test "a refund after a dispute took the purchase back takes nothing more" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())

      assert deliver(event("charge.dispute.funds_withdrawn", dispute(pi, 1_500))).status == 200
      assert deliver(event("charge.refunded", charge(pi, 500))).status == 200

      assert Credits.balance(org.id) == 0
      assert reversals(org) |> Enum.map(& &1.delta) |> Enum.sum() == -15_000
    end

    test "never take back more than the purchase granted" do
      org = wallet_org()
      pi = purchase(org, :tempo, pi_id())

      assert deliver(event("charge.refunded", charge(pi, 1_000))).status == 200
      assert deliver(event("charge.dispute.funds_withdrawn", dispute(pi, 1_500))).status == 200

      assert Credits.balance(org.id) == 0
      assert reversals(org) |> Enum.map(& &1.delta) |> Enum.sum() == -15_000
    end
  end

  describe "metrics" do
    test "count reversals and reinstatements by rail and kind, from the ledger" do
      org = wallet_org()
      refunded = purchase(org, :tempo, pi_id())
      disputed = purchase(org, :mpp, pi_id())

      deliver(event("charge.refunded", charge(refunded, 1_500)))
      du = dispute(disputed)
      deliver(event("charge.dispute.funds_withdrawn", du))
      deliver(event("charge.dispute.funds_reinstated", du))
      deliver(event("charge.refunded", charge(pi_id(), 100)))

      body = Lei.Metrics.collect()

      assert body =~ ~s(lei_credit_reversals{rail="tempo",kind="refund",measure="entries"} 1)
      assert body =~ ~s(lei_credit_reversals{rail="tempo",kind="refund",measure="credits"} 15000)
      assert body =~ ~s(lei_credit_reversals{rail="mpp",kind="dispute",measure="credits"} 15000)

      assert body =~
               ~s(lei_credit_reversals{rail="mpp",kind="reinstatement",measure="credits"} 15000)

      assert body =~ ~s(lei_stripe_reversal_events_total{result="applied"} 3)
      assert body =~ ~s(lei_stripe_reversal_events_total{result="unmatched"} 1)
    end
  end
end
