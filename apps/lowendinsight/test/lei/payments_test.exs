defmodule Lei.PaymentsTest do
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, Credits, Payments}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Payments Org #{System.unique_integer([:positive])}",
        status: "active"
      )

    %{org: org}
  end

  defp settlement(ref, credits \\ 15_000, usd \\ 1500) do
    %{credits: credits, rail: "mpp", settlement_ref: ref, usd_value_cents: usd}
  end

  describe "credit_settlement/2" do
    test "credits the ledger and records the rail", %{org: org} do
      assert {:ok, entry} = Payments.credit_settlement(org.id, settlement("mpp_1"))

      assert entry.delta == 15_000
      assert entry.reason == "purchase:mpp"
      assert entry.external_ref == "mpp_1"
      assert entry.usd_value_cents == 1500
      assert Credits.balance(org.id) == 15_000
    end

    test "a replayed settlement credits exactly once", %{org: org} do
      # Duplicate settlement under concurrency is a documented x402 attack class
      # and the failure this codebase keeps meeting. The unique index is the
      # defence, and this is the assertion that it is load-bearing.
      assert {:ok, _} = Payments.credit_settlement(org.id, settlement("mpp_replay"))
      assert {:error, :duplicate} = Payments.credit_settlement(org.id, settlement("mpp_replay"))

      assert Credits.balance(org.id) == 15_000
    end

    test "the same settlement cannot be credited to a second org", %{org: org} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Payments Other #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _} = Payments.credit_settlement(org.id, settlement("mpp_cross"))

      assert {:error, :duplicate} = Payments.credit_settlement(other.id, settlement("mpp_cross"))
      assert Credits.balance(other.id) == 0
    end

    test "concurrent credits of one settlement produce one grant", %{org: org} do
      results =
        1..6
        |> Task.async_stream(fn _ ->
          Payments.credit_settlement(org.id, settlement("mpp_race"))
        end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Credits.balance(org.id) == 15_000
    end

    test "rails are distinguished in the ledger", %{org: org} do
      {:ok, a} = Payments.credit_settlement(org.id, %{settlement("x_1") | rail: "x402"})
      {:ok, b} = Payments.credit_settlement(org.id, %{settlement("s_1") | rail: "stripe"})

      assert a.reason == "purchase:x402"
      assert b.reason == "purchase:stripe"
    end

    test "an unknown rail is refused by the ledger's reason whitelist", %{org: org} do
      # Adding a rail means adding its reason to Lei.CreditEntry. That is
      # deliberate: a typo in a rail name would otherwise create a category of
      # revenue nothing reconciles.
      assert {:error, %Ecto.Changeset{}} =
               Payments.credit_settlement(org.id, %{settlement("u_1") | rail: "monopoly"})
    end

    test "refuses a non-positive grant", %{org: org} do
      assert_raise FunctionClauseError, fn ->
        Payments.credit_settlement(org.id, settlement("zero", 0))
      end
    end

    test "usd value at receipt is kept separate from face value", %{org: org} do
      # 15,000 credits is $15 of face value; the payment was worth $14.98.
      {:ok, entry} = Payments.credit_settlement(org.id, settlement("mpp_val", 15_000, 1498))

      assert entry.delta == 15_000
      assert entry.usd_value_cents == 1498
    end
  end

  describe "the rail behaviours" do
    test "a machine rail must be able to name a settlement" do
      # settlement_ref becomes external_ref, which carries the unique index. A
      # rail that cannot produce a stable unique reference cannot be integrated
      # safely, so the callback is not optional.
      callbacks = Lei.Payments.MachineRail.behaviour_info(:callbacks)

      assert {:name, 0} in callbacks
      assert {:requirements, 2} in callbacks
      assert {:verify, 2} in callbacks
    end

    test "a human rail settles out of band" do
      callbacks = Lei.Payments.HumanRail.behaviour_info(:callbacks)

      assert {:name, 0} in callbacks
      assert {:checkout, 3} in callbacks
      assert {:handle_event, 1} in callbacks
    end

    test "the two sides are separate behaviours" do
      # Forcing both through one interface would mean pretending an inline
      # 402 exchange and a webhook arriving minutes later are the same shape.
      refute Lei.Payments.MachineRail.behaviour_info(:callbacks) ==
               Lei.Payments.HumanRail.behaviour_info(:callbacks)
    end
  end
end
