defmodule Lei.PaymentsTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.{ApiKeys, CreditEntry, Credits, Payments, Repo}

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
      # Namespaced by rail: external_ref is globally unique, and two rails that
      # mint the same string would otherwise collapse into one another.
      assert entry.external_ref == "mpp:mpp_1"
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

    test "a settlement replayed six times credits once", %{org: org} do
      # Sequential, and named as such. Under the sandbox every task checks out
      # the same connection and DBConnection serialises them, so no two INSERTs
      # are ever in flight -- calling this a concurrency test would overstate
      # what it proves. The genuinely parallel case is below.
      results =
        1..6
        |> Task.async_stream(fn _ ->
          Payments.credit_settlement(org.id, settlement("mpp_race"))
        end)
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Credits.balance(org.id) == 15_000
    end

    @tag :unboxed
    test "genuinely parallel writers produce one grant" do
      # Outside the sandbox, so each task gets its own connection and the
      # INSERTs really do race. This is the documented x402 attack class --
      # duplicate settlement under concurrency -- and the unique index is the
      # only thing standing between it and double-credited money.
      #
      # Real rows, so they are cleaned up explicitly rather than rolled back.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Lei.Repo, fn ->
        name = "Payments Race #{System.unique_integer([:positive])}"
        {:ok, org} = ApiKeys.find_or_create_org(name, status: "active")
        ref = "race-#{System.unique_integer([:positive])}"

        try do
          results =
            1..8
            |> Task.async_stream(
              fn _ ->
                Ecto.Adapters.SQL.Sandbox.unboxed_run(Lei.Repo, fn ->
                  Payments.credit_settlement(org.id, %{
                    credits: 15_000,
                    rail: "mpp",
                    settlement_ref: ref,
                    usd_value_cents: 1500
                  })
                end)
              end,
              max_concurrency: 8,
              timeout: 15_000
            )
            |> Enum.map(fn {:ok, r} -> r end)

          assert Enum.count(results, &match?({:ok, _}, &1)) == 1,
                 "expected exactly one grant, got #{inspect(results)}"

          # The other seven must be refused by the unique index specifically.
          # Counting only successes would also pass if they had failed for some
          # unrelated reason -- a connection error, a crashed task -- which
          # would prove nothing about duplicate settlement.
          assert Enum.count(results, &match?({:error, :duplicate}, &1)) == 7,
                 "expected seven constraint refusals, got #{inspect(results)}"

          assert Credits.balance(org.id) == 15_000
        after
          Repo.delete_all(from(e in CreditEntry, where: e.org_id == ^org.id))
          Repo.delete_all(from(k in Lei.ApiKey, where: k.org_id == ^org.id))
          Repo.delete_all(from(o in Lei.Org, where: o.id == ^org.id))
        end
      end)
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

    test "two rails may use the same reference without colliding", %{org: org} do
      # A Stripe event id and an x402 nonce are independent namespaces. Before
      # they were namespaced, the second of these was refused as a replay --
      # money taken, credits withheld, nothing in the ledger to find it by.
      assert {:ok, a} =
               Payments.credit_settlement(org.id, %{settlement("shared-1") | rail: "mpp"})

      assert {:ok, b} =
               Payments.credit_settlement(org.id, %{settlement("shared-1") | rail: "x402"})

      refute a.external_ref == b.external_ref
      assert Credits.balance(org.id) == 30_000
    end

    test "the payer and jurisdiction survive the boundary", %{org: org} do
      # A settlement was recording less than a debit does. For the entry an
      # audit would need to trace back to a payer, that is backwards.
      {:ok, entry} =
        Payments.credit_settlement(org.id, %{
          credits: 15_000,
          rail: "x402",
          settlement_ref: "0xabc",
          usd_value_cents: 1500,
          jurisdiction: "US-CA",
          payer: "0xdeadbeef"
        })

      assert entry.jurisdiction == "US-CA"
      assert entry.metadata["payer"] == "0xdeadbeef"
      assert entry.metadata["rail"] == "x402"
      assert entry.metadata["rail_ref"] == "0xabc"
    end

    test "optional fields are simply absent rather than nil-stuffed", %{org: org} do
      {:ok, entry} =
        Payments.credit_settlement(org.id, %{
          credits: 100,
          rail: "mpp",
          settlement_ref: "minimal"
        })

      assert entry.metadata == %{"rail" => "mpp", "rail_ref" => "minimal"}
      assert is_nil(entry.jurisdiction)
      assert is_nil(entry.usd_value_cents)
    end

    test "usd value at receipt is kept separate from face value", %{org: org} do
      # 15,000 credits is $15 of face value; the payment was worth $14.98.
      {:ok, entry} = Payments.credit_settlement(org.id, settlement("mpp_val", 15_000, 1498))

      assert entry.delta == 15_000
      assert entry.usd_value_cents == 1498
    end
  end

  describe "a settlement records what actually happened" do
    test "keeps what was paid separate from what it was worth and what we granted", %{org: org} do
      # Three different numbers. Keeping only the USD value loses the ability
      # to reconcile against the rail's own records.
      {:ok, entry} =
        Payments.credit_settlement(org.id, %{
          credits: 15_000,
          rail: "mpp",
          settlement_ref: "mpp_asset",
          usd_value_cents: 1498,
          asset: "USDC",
          amount: "14.980000"
        })

      assert entry.delta == 15_000
      assert entry.usd_value_cents == 1498
      assert entry.metadata["asset"] == "USDC"
      assert entry.metadata["amount"] == "14.980000"
    end

    test "relates settlements that came from one authorisation", %{org: org} do
      # MPP authorises a limit once and settles repeatedly against it, so a
      # session produces many settlements. Without this they are unrelatable.
      for n <- 1..3 do
        {:ok, _} =
          Payments.credit_settlement(org.id, %{
            credits: 500,
            rail: "mpp",
            settlement_ref: "stream-#{n}",
            authorization_ref: "auth-session-1"
          })
      end

      entries = Credits.entries(org.id)

      assert length(entries) == 3
      assert Enum.all?(entries, &(&1.metadata["authorization_ref"] == "auth-session-1"))
      assert Credits.balance(org.id) == 1500
    end
  end

  describe "reversals" do
    test "a refund takes the credits back", %{org: org} do
      {:ok, _} = Payments.credit_settlement(org.id, settlement("pi_refundable"))
      assert Credits.balance(org.id) == 15_000

      {:ok, entry} =
        Payments.reverse_settlement(org.id, %{
          credits: 15_000,
          rail: "mpp",
          settlement_ref: "re_1"
        })

      assert entry.delta == -15_000
      assert entry.reason == "reversal:mpp"
      assert Credits.balance(org.id) == 0
    end

    test "the purchase it reverses stays in the ledger", %{org: org} do
      # Append-only: the reversal is a new entry, not an edit. "How did this
      # balance get here" stays answerable.
      {:ok, _} = Payments.credit_settlement(org.id, settlement("pi_kept"))

      {:ok, _} =
        Payments.reverse_settlement(org.id, %{
          credits: 15_000,
          rail: "mpp",
          settlement_ref: "re_kept",
          reverses: "pi_kept"
        })

      reasons = Credits.entries(org.id) |> Enum.map(& &1.reason) |> Enum.sort()

      assert reasons == ["purchase:mpp", "reversal:mpp"]

      assert Enum.find(Credits.entries(org.id), &(&1.reason == "reversal:mpp")).metadata[
               "reverses"
             ] ==
               "pi_kept"
    end

    test "a reversal carrying the original payment's id does not collide with it", %{org: org} do
      # Rails often identify a refund by the payment it reverses. Without the
      # second namespace the refund would be refused as a duplicate of the
      # purchase, and the money would go back with no record of it.
      {:ok, _} = Payments.credit_settlement(org.id, %{settlement("same-id") | rail: "stripe"})

      assert {:ok, _} =
               Payments.reverse_settlement(org.id, %{
                 credits: 15_000,
                 rail: "stripe",
                 settlement_ref: "same-id"
               })

      assert Credits.balance(org.id) == 0
    end

    test "a replayed reversal only reverses once", %{org: org} do
      {:ok, _} = Payments.credit_settlement(org.id, settlement("pi_once"))

      reversal = %{credits: 15_000, rail: "mpp", settlement_ref: "re_once"}

      assert {:ok, _} = Payments.reverse_settlement(org.id, reversal)
      assert {:error, :duplicate} = Payments.reverse_settlement(org.id, reversal)
      assert Credits.balance(org.id) == 0
    end

    test "a reversal may take the balance negative", %{org: org} do
      # An org that spent its credits and then charged back has a real debt.
      # Refusing to record it loses the fact rather than preventing it.
      {:ok, _} = Payments.credit_settlement(org.id, %{settlement("pi_spent") | credits: 100})
      {:ok, _} = Credits.debit(org.id, 100, "debit:analysis")

      {:ok, _} =
        Payments.reverse_settlement(org.id, %{
          credits: 100,
          rail: "mpp",
          settlement_ref: "re_negative"
        })

      assert Credits.balance(org.id) == -100
    end
  end

  describe "the boot check has something to check" do
    test "at least one rail is configured" do
      # validate_rails!/0 passes trivially on an empty list -- it refuses bad
      # names and contradictory cadences, and an empty list has neither. The
      # rail shipped unconfigured once, so the boot guarantee was nominal: a
      # misnamed rail would have sailed through because there were no rails.
      rails = Application.get_env(:lei_service, :payment_rails, [])

      assert rails != [],
             "no payment rails configured, so validate_rails!/0 checks nothing"
    end

    test "every configured rail passes the check it exists for" do
      assert :ok = Payments.validate_rails!()
    end

    test "every configured rail can actually write to the ledger" do
      # The reason whitelist fires at insert time, after a rail has verified a
      # real payment. A name the ledger will not accept means money taken and
      # no entry to find it by.
      for rail <- Application.get_env(:lei_service, :payment_rails, []) do
        assert rail.name() in Payments.known_rails(),
               "#{inspect(rail)} is configured but #{rail.name()} is not a ledger reason"
      end
    end
  end

  describe "rail names are checked before money moves" do
    defmodule GoodRail do
      @behaviour Lei.Payments.MachineRail
      def name, do: "mpp"
      def cadences, do: [:one_shot, :streaming]
      def minimum_purchase_credits, do: nil
      def requirements(_credits, _opts), do: {:ok, %{}}
      def verify(_proof, _opts), do: {:error, :not_implemented}
    end

    defmodule TypoRail do
      @behaviour Lei.Payments.MachineRail
      def name, do: "mmp"
      def cadences, do: [:one_shot]
      def minimum_purchase_credits, do: 15_000
      def requirements(_credits, _opts), do: {:ok, %{}}
      def verify(_proof, _opts), do: {:error, :not_implemented}
    end

    defmodule SilentRail do
      @behaviour Lei.Payments.MachineRail
      def name, do: "x402"
      def cadences, do: []
      def minimum_purchase_credits, do: nil
      def requirements(_credits, _opts), do: {:ok, %{}}
      def verify(_proof, _opts), do: {:error, :not_implemented}
    end

    defmodule ContradictoryRail do
      @behaviour Lei.Payments.MachineRail
      def name, do: "x402"
      def cadences, do: [:streaming]
      def minimum_purchase_credits, do: 15_000
      def requirements(_credits, _opts), do: {:ok, %{}}
      def verify(_proof, _opts), do: {:error, :not_implemented}
    end

    defmodule NonsenseRail do
      @behaviour Lei.Payments.MachineRail
      def name, do: "x402"
      def cadences, do: [:one_shot, :hourly]
      def minimum_purchase_credits, do: nil
      def requirements(_credits, _opts), do: {:ok, %{}}
      def verify(_proof, _opts), do: {:error, :not_implemented}
    end

    test "known rails come from the ledger's whitelist, not a second list" do
      # Two lists drift. This one is derived, so it cannot.
      assert "mpp" in Payments.known_rails()
      assert "x402" in Payments.known_rails()
      assert "stripe" in Payments.known_rails()
      refute "debit" in Payments.known_rails()
    end

    test "a well-named rail passes validation" do
      assert :ok = Payments.validate_rails!([GoodRail])
    end

    test "a typo is refused at boot rather than at insert" do
      # Without this the whitelist still catches it -- but only after the rail
      # has verified a real payment, so the money is taken and the insert that
      # would have recorded it is the thing that fails.
      assert_raise ArgumentError, ~r/mmp/, fn ->
        Payments.validate_rails!([TypoRail])
      end
    end

    test "no configured rails is not an error" do
      assert :ok = Payments.validate_rails!([])
    end

    test "a rail that declares no cadence is refused" do
      # Nothing could ever be bought through it, and finding that out at the
      # first payment means finding it out from a customer.
      assert_raise ArgumentError, ~r/no cadences/, fn ->
        Payments.validate_rails!([SilentRail])
      end
    end

    test "an unknown cadence is refused" do
      assert_raise ArgumentError, ~r/hourly/, fn ->
        Payments.validate_rails!([NonsenseRail])
      end
    end

    test "streaming with a minimum purchase is a contradiction" do
      # Streaming settles per interaction, so there is no purchase for a
      # minimum to apply to. A rail claiming both has one of them wrong, and
      # which one changes how it should be built.
      assert_raise ArgumentError, ~r/:streaming and a minimum purchase/, fn ->
        Payments.validate_rails!([ContradictoryRail])
      end
    end

    test "a block-selling rail may state a floor" do
      # Card fees carry a fixed 30c: 6000% of one cache hit, 4.9% of a $15
      # block. The floor is the rail's economics, stated where code can read it.
      assert :ok = Payments.validate_rails!([GoodRail])
      assert GoodRail.minimum_purchase_credits() == nil
      assert TypoRail.minimum_purchase_credits() == 15_000
    end

    test "the cadences are the three MPP names, not an open set" do
      assert Payments.cadences() == [:one_shot, :recurring, :streaming]
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
