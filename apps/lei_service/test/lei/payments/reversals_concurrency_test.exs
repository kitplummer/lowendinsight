defmodule Lei.Payments.ReversalsConcurrencyTest do
  @moduledoc """
  Refund events for one purchase, processed at once, take it back once (#208).

  `charge.refunded` carries a cumulative amount, and what to reverse is computed
  as that amount less what the ledger already holds. Two events read without a
  lock both see nothing reversed yet, and both write: a $5 and a $15 refund on
  a $15 purchase would take back $20 of credits.

  Stripe delivers each event separately and makes no promise about order or
  spacing, and with two machines they can land on different nodes.

  Like `Lei.AdmissionConcurrencyTest`, this does not use the SQL sandbox: a
  shared sandbox connection runs one query at a time, which serialises exactly
  the interleaving under test.
  """
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.{
    CreditEntry,
    Credits,
    Org,
    Payments,
    Repo,
    StripeEvent,
    StripeWebhookHandler,
    Wallets
  }

  @created {__MODULE__, :created}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    :persistent_term.put(@created, {[], []})

    on_exit(fn ->
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
      {orgs, events} = :persistent_term.get(@created, {[], []})
      Repo.delete_all(from(e in CreditEntry, where: e.org_id in ^orgs))
      Repo.delete_all(from(k in Lei.ApiKey, where: k.org_id in ^orgs))
      Repo.delete_all(from(o in Org, where: o.id in ^orgs))
      Repo.delete_all(from(e in StripeEvent, where: e.id in ^events))
      :persistent_term.erase(@created)
    end)

    :ok
  end

  defp track(kind, value) do
    {orgs, events} = :persistent_term.get(@created)

    :persistent_term.put(
      @created,
      if(kind == :org, do: {[value | orgs], events}, else: {orgs, [value | events]})
    )

    value
  end

  defp refund_event(pi, refunded) do
    id = track(:event, "evt_concurrency_#{System.unique_integer([:positive])}")

    %{
      "id" => id,
      "type" => "charge.refunded",
      "data" => %{
        "object" => %{
          "id" => "ch_concurrency",
          "object" => "charge",
          "amount" => 1_500,
          "amount_refunded" => refunded,
          "currency" => "usd",
          "payment_intent" => pi
        }
      }
    }
  end

  test "overlapping refunds on one purchase never take back more than it granted" do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Wallets.provision(address)
    track(:org, org.id)
    pi = "pi_concurrency_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Payments.credit_settlement(org.id, %{
        credits: 15_000,
        rail: "tempo",
        settlement_ref: pi,
        usd_value_cents: 1_500
      })

    # Three events at three cumulative levels, so no two share a ledger ref
    # and the unique index cannot stand in for the lock. Whichever commits
    # last, the purchase is fully refunded exactly once.
    [500, 1_000, 1_500]
    |> Enum.map(&refund_event(pi, &1))
    |> Enum.map(fn event ->
      Task.async(fn ->
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
        StripeWebhookHandler.process(event)
      end)
    end)
    |> Enum.each(&({:ok, :processed} = Task.await(&1, 30_000)))

    assert Credits.balance(org.id) == 0
  end
end
