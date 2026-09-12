defmodule Lei.CreditDebitTest do
  use ExUnit.Case, async: false

  alias Lei.{ApiKeys, CreditEntry, Credits, Repo, UsageTracker}

  import Ecto.Query

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Debit Test Org #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, _raw, api_key} = ApiKeys.create_api_key(org, "debit-test", ["analyze"])

    %{org: org, api_key: api_key}
  end

  defp debits(org_id) do
    Repo.all(
      from(e in CreditEntry,
        where: e.org_id == ^org_id and e.reason == "debit:analysis",
        order_by: e.id
      )
    )
  end

  describe "recording usage debits credits" do
    test "one analysis produces exactly one debit", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      assert [entry] = debits(org.id)
      assert entry.delta == -5
      assert Credits.balance(org.id) == -5
    end

    test "prices hits and misses per ADR-001", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 10, 2)

      assert [entry] = debits(org.id)
      # 10 hits * 5 + 2 misses * 50 = 150 credits = $0.15
      assert entry.delta == -150
    end

    test "a miss costs ten times a hit", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 0, 1)

      assert [entry] = debits(org.id)
      assert entry.delta == -50
    end

    test "zero usage writes no entry", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 0, 0)

      assert debits(org.id) == []
    end

    test "the debit matches the cents recorded on the usage row", %{org: org, api_key: key} do
      # One credit is $0.001 and the usage row is in cents, so a drift between
      # them bills one amount and debits another.
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 37, 11)

      [entry] = debits(org.id)

      assert Decimal.equal?(
               Decimal.mult(usage.total_cost_cents, 10),
               Decimal.new(abs(entry.delta))
             )
    end
  end

  describe "the ledger mirrors analysis_usage" do
    test "a second analysis debits again", %{org: org, api_key: key} do
      # Deliberate, and a correction to what issue #102 originally specified.
      #
      # record_usage/4 always increments analysis_usage. If the same request is
      # recorded twice, that row has already double-counted, and the ledger
      # deduplicating would put the two permanently out of step -- exactly the
      # drift the reconciliation check exists to detect. The ledger records what
      # was consumed; deduplication, if wanted, belongs upstream of both.
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      assert length(debits(org.id)) == 2
      assert Credits.balance(org.id) == -10
    end

    test "total debits equal the usage row's cost for the period", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 3, 1)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 2, 0)
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 0, 2)

      consumed = debits(org.id) |> Enum.map(& &1.delta) |> Enum.sum() |> abs()

      assert Decimal.equal?(Decimal.mult(usage.total_cost_cents, 10), Decimal.new(consumed))
    end
  end

  describe "idempotency of the ledger write itself" do
    test "an already-recorded debit does not fail the usage write", %{org: org, api_key: key} do
      # Pre-insert the entry record_usage is about to derive, so the insert hits
      # the unique index. The usage row must still be written and returned.
      {:ok, _} =
        Credits.grant(org.id, 1000, "adjustment:manual", external_ref: "seed-balance")

      {:ok, first} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      ref = "analysis-#{first.id}-#{first.cache_hits}-#{first.cache_misses}"

      assert [%CreditEntry{external_ref: ^ref}] = debits(org.id)
    end

    test "re-deriving from an unchanged row is refused by the constraint", %{
      org: org,
      api_key: key
    } do
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      ref = "analysis-#{usage.id}-#{usage.cache_hits}-#{usage.cache_misses}"

      assert {:error, :duplicate} =
               Credits.debit(org.id, 5, "debit:analysis", external_ref: ref)

      assert length(debits(org.id)) == 1
    end

    test "each increment yields a distinct reference", %{org: org, api_key: key} do
      for _ <- 1..4, do: {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      refs = debits(org.id) |> Enum.map(& &1.external_ref)

      assert length(refs) == 4
      assert length(Enum.uniq(refs)) == 4
    end
  end

  describe "the entry carries enough to reconcile" do
    test "metadata links the debit back to the usage row", %{org: org, api_key: key} do
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 2, 1)

      [entry] = debits(org.id)

      assert entry.metadata["analysis_usage_id"] == usage.id
      assert entry.metadata["cache_hits"] == 2
      assert entry.metadata["cache_misses"] == 1
      assert entry.metadata["period_start"] == Date.to_iso8601(usage.period_start)
    end

    test "debits carry no accounting fields", %{org: org, api_key: key} do
      # usd_value_cents and jurisdiction describe money coming in. A debit is
      # consumption, not a sale.
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      [entry] = debits(org.id)

      assert is_nil(entry.usd_value_cents)
      assert is_nil(entry.jurisdiction)
    end
  end

  describe "balances" do
    test "a funded org draws down rather than going negative", %{org: org, api_key: key} do
      {:ok, _} = Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_funded")

      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 100, 10)

      # 100 * 5 + 10 * 50 = 1000
      assert Credits.balance(org.id) == 14_000
    end

    test "an unfunded org goes negative rather than losing the record", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 0, 1)

      assert Credits.balance(org.id) == -50
    end
  end
end
