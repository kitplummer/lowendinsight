defmodule Lei.AcpCreditsTest do
  @moduledoc """
  Agent checkout (ACP) sells credits, not a tier.

  `lei-pro-monthly` charged $29 once through a PaymentIntent and created a
  `tier: "pro"` org. Pro is unlimited at the gate and metered only through a
  Stripe subscription, which a one-off charge never creates -- so the org was
  never billed again and nothing could ever suspend it (ADR-002, "Money only
  exists as Stripe state").

  `lei-free` handed any caller a free org with a monthly allowance, which
  ADR-002 rules out for agents: an org costs nothing to create through ACP, so
  a per-org allowance is a per-attacker one.

  Decided 2026-09-14: a purchase grants credits proportional to the amount, on
  a prepaid org with no allowance of its own. There is no free SKU.
  """
  use ExUnit.Case, async: false

  import Mox

  alias Lei.{Acp, Credits, Repo}

  setup :verify_on_exit!

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  @sku "lei-credits-29000"

  defp paid_session(name \\ nil) do
    {:ok, session} = Acp.create_session(@sku)
    name = name || "ACP Credits #{System.unique_integer([:positive])}"
    {:ok, session} = Acp.update_session(session.id, %{customer_name: name})
    session
  end

  defp stripe_succeeds(pi_id \\ "pi_acp_credits") do
    expect(Lei.StripeMock, :create_payment_intent, fn %{amount: 2900} ->
      {:ok, %{"id" => pi_id, "status" => "succeeded"}}
    end)
  end

  describe "the catalogue" do
    test "there is no free SKU" do
      assert {:error, :invalid_sku} = Acp.create_session("lei-free")
      refute "lei-free" in Lei.AcpCheckoutSession.valid_skus()
    end

    test "the Pro subscription SKU is gone; credits are sold instead" do
      assert {:error, :invalid_sku} = Acp.create_session("lei-pro-monthly")
      assert {:ok, %{amount_cents: 2900}} = Acp.create_session(@sku)
    end
  end

  describe "completing a purchase" do
    test "creates a prepaid org holding credits for what was paid, not a Pro org" do
      session = paid_session()
      stripe_succeeds()

      assert {:ok, result} =
               Acp.complete_session(session.id, %{"payment_method" => "pm_card_visa"})

      org = Repo.get_by!(Lei.Org, slug: result.org_slug)
      refute org.tier == "pro"
      assert org.prepaid
      assert org.free_tier_analyses_limit == 0

      assert Credits.balance(org.id) == 29_000
      assert result.credits == 29_000
      refute result.tier == "pro"

      [entry] = Credits.entries(org.id)
      assert entry.reason == "purchase:stripe"
      assert entry.external_ref == "acp:pi_acp_credits"
      assert entry.usd_value_cents == 2900
    end

    test "the purchased org is admitted on its balance, and refused when it is spent" do
      session = paid_session()
      stripe_succeeds()
      {:ok, result} = Acp.complete_session(session.id, %{"payment_method" => "pm_card_visa"})
      org = Repo.get_by!(Lei.Org, slug: result.org_slug)

      assert {:ok, 29_000} = Lei.UsageTracker.check_free_tier_quota(org.id)

      {:ok, _} = Credits.debit(org.id, 29_000, "debit:analysis")

      assert {:error, :insufficient_credits, %{balance: 0}} =
               Lei.UsageTracker.check_free_tier_quota(org.id)
    end

    test "a failed payment creates nothing and does not echo Stripe's error body" do
      session = paid_session()

      expect(Lei.StripeMock, :create_payment_intent, fn _ ->
        {:error,
         %{
           "error" => %{
             "code" => "card_declined",
             "payment_intent" => %{"client_secret" => "pi_x_secret_y"}
           }
         }}
      end)

      assert {:error, {:payment_failed, reason}} =
               Acp.complete_session(session.id, %{"payment_method" => "pm_card_chargeDeclined"})

      refute inspect(reason) =~ "secret"
      assert Repo.aggregate(Lei.CreditEntry, :count) == 0
    end

    test "a taken name is refused before the card is charged" do
      {:ok, _} = Lei.ApiKeys.create_org("Taken Agent Name", tier: "free", status: "active")
      session = paid_session("Taken Agent Name")

      # No create_payment_intent expectation: charging here would take money
      # for an org that cannot be created.
      assert {:error, :name_taken} =
               Acp.complete_session(session.id, %{"payment_method" => "pm_card_visa"})
    end
  end

  test "wallet orgs are prepaid" do
    address = "0x" <> (:crypto.strong_rand_bytes(20) |> Base.encode16(case: :lower))
    {:ok, org} = Lei.Wallets.provision(address)
    assert org.prepaid
  end
end
