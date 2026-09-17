defmodule Lei.StripeReconciliationTest do
  @moduledoc """
  The ledger's purchases and Stripe's payments are compared, both ways, every
  hour (#139, stage F).

  Before this, the only reconciliation was the ledger against recorded usage
  (#120). Nothing checked that a purchase the ledger credited was money Stripe
  actually received, or that money Stripe received for a purchase was ever
  credited. Either can happen -- a bug in a rail, a lost webhook, a race -- and
  both would pass every other check.

  Compared per PaymentIntent, not against Stripe's balance: the balance moves
  with fees, payouts and subscriptions, and a total that agrees can hide two
  errors that cancel. The shapes below follow a real sandbox listing taken on
  2026-09-17 (`GET /v1/payment_intents?expand[]=data.latest_charge`): stablecoin
  and MPP card PaymentIntents carry `metadata.challenge_id`, a Pro subscription
  payment carries none, and agent card checkout (ACP) carried none until this
  change added `metadata.lei_rail`.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.{Credits, Payments, Repo, StripeReconciliation, Wallets}

  setup :verify_on_exit!

  @now ~U[2026-09-17 12:00:00Z]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    saved = Application.get_env(:lei_service, :stripe_secret_key)
    Application.put_env(:lei_service, :stripe_secret_key, "sk_test_" <> String.duplicate("x", 24))

    on_exit(fn ->
      if saved,
        do: Application.put_env(:lei_service, :stripe_secret_key, saved),
        else: Application.delete_env(:lei_service, :stripe_secret_key)
    end)

    {:ok, org} =
      Wallets.provision("0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower)))

    %{org: org}
  end

  # -- fixtures

  defp unix(%DateTime{} = at), do: DateTime.to_unix(at)
  defp ago(minutes), do: DateTime.add(@now, -minutes * 60, :second)

  defp purchase(org, rail, pi, opts \\ []) do
    cents = Keyword.get(opts, :cents, 1_500)
    at = Keyword.get(opts, :at, ago(60))

    {:ok, entry} =
      case rail do
        "acp" ->
          Credits.grant(org.id, cents * 10, "purchase:stripe",
            external_ref: "acp:" <> pi,
            usd_value_cents: cents
          )

        rail ->
          Payments.credit_settlement(org.id, %{
            credits: cents * 10,
            rail: rail,
            settlement_ref: pi,
            usd_value_cents: cents
          })
      end

    entry |> Ecto.Changeset.change(inserted_at: DateTime.to_naive(at)) |> Repo.update!()
  end

  defp intent(id, overrides \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "object" => "payment_intent",
        "status" => "succeeded",
        "amount" => 1_500,
        "amount_received" => 1_500,
        "currency" => "usd",
        "livemode" => false,
        "created" => unix(ago(60)),
        "metadata" => %{"challenge_id" => "ch_#{id}", "credits" => "15000"},
        "latest_charge" => %{"id" => "ch_" <> id, "amount_refunded" => 0}
      },
      overrides
    )
  end

  defp stripe_lists(intents, has_more \\ false) do
    expect(Lei.StripeMock, :list_payment_intents, fn _since, nil ->
      {:ok, %{"data" => intents, "has_more" => has_more}}
    end)
  end

  defp run, do: StripeReconciliation.run(now: @now)

  defp kinds({:ok, run}), do: run.discrepancies |> Enum.map(& &1["kind"]) |> Enum.sort()

  # -- both agree

  test "a purchase the ledger and Stripe both record is clean", %{org: org} do
    purchase(org, "tempo", "pi_agree")
    stripe_lists([intent("pi_agree")])

    assert {:ok, run} = run()
    assert run.status == "ok"
    assert run.ledger_purchases == 1
    assert run.stripe_purchases == 1
    assert run.discrepancy_count == 0
  end

  test "an agent card checkout is matched through its lei_rail metadata", %{org: org} do
    purchase(org, "acp", "pi_acp", cents: 2_900)

    stripe_lists([
      intent("pi_acp", %{
        "amount" => 2_900,
        "amount_received" => 2_900,
        "metadata" => %{"lei_rail" => "acp", "acp_session_id" => "acp_cs_1", "credits" => "29000"}
      })
    ])

    assert {:ok, %{status: "ok", discrepancy_count: 0}} = run()
  end

  # -- recorded, not received

  test "a purchase Stripe has no record of is money credited and never received", %{org: org} do
    purchase(org, "mpp", "pi_ghost")
    stripe_lists([])

    expect(Lei.StripeMock, :retrieve_payment_intent, fn "pi_ghost" ->
      {:error, %{"error" => %{"code" => "resource_missing"}}}
    end)

    assert run() |> kinds() == ["missing_in_stripe"]
  end

  test "a purchase created before the window's listing is fetched on its own", %{org: org} do
    purchase(org, "tempo", "pi_older_intent")
    stripe_lists([])

    expect(Lei.StripeMock, :retrieve_payment_intent, fn "pi_older_intent" ->
      {:ok, intent("pi_older_intent", %{"created" => unix(ago(8 * 24 * 60))})}
    end)

    assert {:ok, %{status: "ok"}} = run()
  end

  test "a purchase credited for more than Stripe received", %{org: org} do
    purchase(org, "tempo", "pi_short", cents: 1_500)
    stripe_lists([intent("pi_short", %{"amount_received" => 1_000})])

    assert run() |> kinds() == ["amount_mismatch"]
  end

  test "a purchase whose payment has not succeeded", %{org: org} do
    purchase(org, "tempo", "pi_processing")
    stripe_lists([intent("pi_processing", %{"status" => "processing", "amount_received" => 0})])

    assert "not_succeeded" in kinds(run())
  end

  test "a purchase recorded against the other mode's Stripe", %{org: org} do
    purchase(org, "tempo", "pi_live")
    stripe_lists([intent("pi_live", %{"livemode" => true})])

    assert run() |> kinds() == ["mode_mismatch"]
  end

  test "a refund Stripe made that the ledger never reversed", %{org: org} do
    purchase(org, "tempo", "pi_refunded")

    stripe_lists([
      intent("pi_refunded", %{"latest_charge" => %{"id" => "ch_r", "amount_refunded" => 500}})
    ])

    assert run() |> kinds() == ["refund_not_recorded"]
  end

  test "a refund the ledger has reversed is clean", %{org: org} do
    purchase(org, "tempo", "pi_reversed")

    :applied =
      Payments.Reversals.refund(%{
        "id" => "ch_rev",
        "payment_intent" => "pi_reversed",
        "amount_refunded" => 500,
        "currency" => "usd"
      })

    stripe_lists([
      intent("pi_reversed", %{"latest_charge" => %{"id" => "ch_rev", "amount_refunded" => 500}})
    ])

    assert {:ok, %{status: "ok"}} = run()
  end

  # -- received, not recorded

  test "a purchase Stripe received that the ledger never credited" do
    stripe_lists([intent("pi_uncredited", %{"created" => unix(ago(60))})])

    assert run() |> kinds() == ["received_not_recorded"]
  end

  test "a payment still inside the grace period is not yet expected in the ledger" do
    # A stablecoin payment succeeds at Stripe seconds before the ledger entry
    # is written.
    stripe_lists([intent("pi_just_now", %{"created" => unix(ago(2))})])

    assert {:ok, %{status: "ok", stripe_purchases: 0}} = run()
  end

  test "a payment that is not a credit purchase is none of the ledger's business" do
    stripe_lists([
      intent("pi_subscription", %{"metadata" => %{}, "description" => "Subscription creation"}),
      intent("pi_failed", %{"status" => "requires_payment_method", "amount_received" => 0})
    ])

    assert {:ok, %{status: "ok", stripe_purchases: 0}} = run()
  end

  # -- the window

  test "ledger purchases older than the window are not compared", %{org: org} do
    purchase(org, "tempo", "pi_last_month", at: ago(10 * 24 * 60))
    stripe_lists([])

    assert {:ok, %{status: "ok", ledger_purchases: 0}} = run()
  end

  test "lists from the start of the window, every page" do
    since = unix(DateTime.add(@now, -7 * 86_400, :second))

    expect(Lei.StripeMock, :list_payment_intents, fn ^since, nil ->
      {:ok, %{"data" => [intent("pi_page_1", %{"metadata" => %{}})], "has_more" => true}}
    end)

    expect(Lei.StripeMock, :list_payment_intents, fn ^since, "pi_page_1" ->
      {:ok, %{"data" => [intent("pi_page_2")], "has_more" => false}}
    end)

    assert run() |> kinds() == ["received_not_recorded"]
  end

  # -- when it cannot do its job

  test "a Stripe error is a failed run, not a clean one" do
    expect(Lei.StripeMock, :list_payment_intents, fn _, _ -> {:error, :timeout} end)

    assert {:ok, run} = run()
    assert run.status == "failed"
    assert run.error =~ "timeout"
    assert run.discrepancy_count == nil
  end

  test "more pages than it will read is a failed run, not a truncated clean one" do
    stub(Lei.StripeMock, :list_payment_intents, fn _, _ ->
      {:ok,
       %{
         "data" => [intent("pi_#{System.unique_integer([:positive])}", %{"metadata" => %{}})],
         "has_more" => true
       }}
    end)

    assert {:ok, %{status: "failed", error: error}} =
             StripeReconciliation.run(now: @now, max_pages: 3)

    assert error =~ "more than 3 pages"
  end

  test "without a Stripe key it records that it could not run" do
    Application.delete_env(:lei_service, :stripe_secret_key)

    assert {:ok, %{status: "failed", error: "stripe not configured"}} = run()
  end

  # -- recorded, and visible

  test "each run is kept, and the latest is what metrics report", %{org: org} do
    body = Lei.Metrics.collect()
    assert body =~ ~s(lei_stripe_reconciliation{measure="runs"} 0)

    purchase(org, "mpp", "pi_metrics_ghost")
    stripe_lists([])

    expect(Lei.StripeMock, :retrieve_payment_intent, fn _ ->
      {:error, %{"error" => %{"code" => "resource_missing"}}}
    end)

    {:ok, _} = StripeReconciliation.run(now: DateTime.utc_now())

    body = Lei.Metrics.collect()
    assert body =~ ~s(lei_stripe_reconciliation{measure="runs"} 1)
    assert body =~ ~s(lei_stripe_reconciliation{measure="failed"} 0)
    assert body =~ ~s(lei_stripe_reconciliation{measure="discrepancies"} 1)
    assert body =~ ~s(lei_stripe_reconciliation{measure="ledger_purchases"} 1)
    assert body =~ ~r/lei_stripe_reconciliation\{measure="age_seconds"\} \d+/

    assert %{
             discrepancies: [
               %{"kind" => "missing_in_stripe", "payment_intent" => "pi_metrics_ghost"}
             ]
           } =
             StripeReconciliation.latest()
  end

  test "a failed latest run reports failed, with no discrepancy count to mistake for zero" do
    expect(Lei.StripeMock, :list_payment_intents, fn _, _ -> {:error, :timeout} end)
    {:ok, _} = StripeReconciliation.run(now: DateTime.utc_now())

    body = Lei.Metrics.collect()
    assert body =~ ~s(lei_stripe_reconciliation{measure="failed"} 1)
    refute body =~ ~s(lei_stripe_reconciliation{measure="discrepancies"})
  end

  test "the hourly job runs it and keeps the result" do
    stripe_lists([])

    assert :ok = LeiService.StripeReconciliationWorker.perform(%Oban.Job{args: %{}})
    assert %{status: "ok"} = StripeReconciliation.latest()
  end
end
