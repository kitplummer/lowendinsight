defmodule Lei.CreditsTest do
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, CreditEntry, Credits, Repo}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Credits Test Org #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    %{org: org}
  end

  describe "balance/1" do
    test "is 0 for an org with no entries", %{org: org} do
      # sum over an empty set is NULL in SQL. A nil leaking out of here would
      # blow up or, worse, compare falsely and serve a zero-balance org.
      assert Credits.balance(org.id) == 0
    end

    test "sums grants and debits", %{org: org} do
      {:ok, _} = Credits.grant(org.id, 1000, "purchase:stripe", external_ref: "pi_sum_1")
      {:ok, _} = Credits.debit(org.id, 50, "debit:analysis")
      {:ok, _} = Credits.debit(org.id, 5, "debit:analysis")

      assert Credits.balance(org.id) == 945
    end

    test "goes negative rather than refusing to record consumption", %{org: org} do
      {:ok, _} = Credits.grant(org.id, 10, "adjustment:manual")
      {:ok, _} = Credits.debit(org.id, 50, "debit:analysis")

      assert Credits.balance(org.id) == -40
    end

    test "is scoped to one org", %{org: org} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Credits Other Org #{System.unique_integer([:positive])}",
          tier: "free",
          status: "active"
        )

      {:ok, _} = Credits.grant(org.id, 100, "adjustment:manual")

      assert Credits.balance(org.id) == 100
      assert Credits.balance(other.id) == 0
    end
  end

  describe "external_ref idempotency" do
    test "a replayed ref credits exactly once", %{org: org} do
      {:ok, _} = Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_replay")

      assert {:error, :duplicate} =
               Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_replay")

      assert Credits.balance(org.id) == 15_000
    end

    test "the constraint holds against a concurrent writer", %{org: org} do
      # The sandbox serialises these onto one connection, so this is not a true
      # race. It still proves the thing that matters: nothing in Credits
      # pre-checks for the ref, so the only defence is the unique index. A
      # pre-check-based implementation would need this test to be a real race
      # to fail -- an index-based one fails it here.
      ref = "pi_concurrent"

      results =
        1..5
        |> Task.async_stream(fn _ ->
          Credits.grant(org.id, 100, "purchase:x402", external_ref: ref)
        end)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert Enum.count(results, &match?({:error, :duplicate}, &1)) == 4
      assert Credits.balance(org.id) == 100
    end

    test "entries without a ref are not deduplicated", %{org: org} do
      # Two identical analyses genuinely consume twice. Only refs dedupe.
      {:ok, _} = Credits.debit(org.id, 5, "debit:analysis")
      {:ok, _} = Credits.debit(org.id, 5, "debit:analysis")

      assert Credits.balance(org.id) == -10
    end

    test "the same ref cannot be reused across orgs", %{org: org} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Credits Cross Org #{System.unique_integer([:positive])}",
          tier: "free",
          status: "active"
        )

      {:ok, _} = Credits.grant(org.id, 100, "purchase:x402", external_ref: "0xdeadbeef")

      # A transaction hash settles once. Crediting a second org for it would be
      # the same double-spend in a different shape.
      assert {:error, :duplicate} =
               Credits.grant(other.id, 100, "purchase:x402", external_ref: "0xdeadbeef")
    end
  end

  describe "append-only" do
    test "a repeated grant writes a new row rather than updating", %{org: org} do
      {:ok, first} = Credits.grant(org.id, 100, "grant:subscription")
      {:ok, second} = Credits.grant(org.id, 100, "grant:subscription")

      refute first.id == second.id
      assert Credits.balance(org.id) == 200
      assert length(Credits.entries(org.id)) == 2
    end

    test "entries carry no updated_at to modify", %{org: org} do
      {:ok, entry} = Credits.grant(org.id, 100, "grant:subscription")

      refute Map.has_key?(entry, :updated_at)
      assert entry.inserted_at
    end
  end

  describe "changeset validation" do
    test "rejects a zero delta", %{org: org} do
      changeset =
        CreditEntry.changeset(%CreditEntry{}, %{
          org_id: org.id,
          delta: 0,
          reason: "adjustment:manual"
        })

      refute changeset.valid?
    end

    test "rejects an unknown reason", %{org: org} do
      changeset =
        CreditEntry.changeset(%CreditEntry{}, %{
          org_id: org.id,
          delta: 10,
          reason: "purchase:monopoly-money"
        })

      refute changeset.valid?
    end

    test "refuses a grant of zero or less", %{org: org} do
      assert_raise FunctionClauseError, fn -> Credits.grant(org.id, 0, "adjustment:manual") end
      assert_raise FunctionClauseError, fn -> Credits.debit(org.id, -5, "debit:analysis") end
    end
  end

  describe "accounting fields" do
    test "records USD value at receipt separately from face value", %{org: org} do
      # 15,000 credits is $15 of face value, but the USDC actually received was
      # worth $14.98. ADR-002: store both, because the difference is
      # unrecoverable afterwards.
      {:ok, entry} =
        Credits.grant(org.id, 15_000, "purchase:x402",
          external_ref: "0xvaluation",
          usd_value_cents: 1498,
          jurisdiction: "US-CA"
        )

      assert entry.delta == 15_000
      assert entry.usd_value_cents == 1498
      assert entry.jurisdiction == "US-CA"
    end

    test "usd_value_cents and jurisdiction are optional", %{org: org} do
      {:ok, entry} = Credits.debit(org.id, 5, "debit:analysis")

      assert is_nil(entry.usd_value_cents)
      assert is_nil(entry.jurisdiction)
    end

    test "deferred revenue is derivable from the ledger", %{org: org} do
      # sum(grants) is liability incurred, sum(debits) is revenue recognised,
      # and the total is what remains deferred. This is the reason the ledger
      # is append-only rather than a balance column.
      {:ok, _} = Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_deferred")
      {:ok, _} = Credits.debit(org.id, 500, "debit:analysis")

      entries = Credits.entries(org.id)
      granted = entries |> Enum.map(& &1.delta) |> Enum.filter(&(&1 > 0)) |> Enum.sum()
      consumed = entries |> Enum.map(& &1.delta) |> Enum.filter(&(&1 < 0)) |> Enum.sum()

      assert granted == 15_000
      assert consumed == -500
      assert granted + consumed == Credits.balance(org.id)
    end
  end

  describe "cost_in_credits/2" do
    test "prices hits and misses per ADR-001" do
      assert Credits.cost_in_credits(1, 0) == 5
      assert Credits.cost_in_credits(0, 1) == 50
      assert Credits.cost_in_credits(10, 2) == 150
      assert Credits.cost_in_credits(0, 0) == 0
    end

    test "matches the cents the usage tracker computes" do
      # One credit is $0.001 and UsageTracker works in cents, so credits must be
      # ten times the cent cost. If these drift, an org is billed one amount and
      # debited another.
      hits = 37
      misses = 11

      cents = Lei.UsageTracker.calculate_cost(hits, misses)
      credits = Credits.cost_in_credits(hits, misses)

      assert Decimal.equal?(Decimal.mult(cents, 10), Decimal.new(credits))
    end
  end

  describe "entries/2" do
    test "returns newest first and honours a limit", %{org: org} do
      for n <- 1..5, do: {:ok, _} = Credits.grant(org.id, n * 10, "adjustment:manual")

      entries = Credits.entries(org.id, limit: 3)

      assert length(entries) == 3
      assert Enum.map(entries, & &1.delta) == [50, 40, 30]
    end

    test "is empty for an org with no entries", %{org: org} do
      assert Credits.entries(org.id) == []
    end
  end

  describe "persistence" do
    test "entries survive as rows, not process state", %{org: org} do
      {:ok, entry} = Credits.grant(org.id, 100, "grant:subscription")

      assert %CreditEntry{delta: 100} = Repo.get(CreditEntry, entry.id)
    end
  end
end
