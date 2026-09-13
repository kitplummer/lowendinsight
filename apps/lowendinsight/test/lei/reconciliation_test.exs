defmodule Lei.ReconciliationTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Lei.{ApiKeys, CreditEntry, Reconciliation, Repo, UsageTracker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Recon Org #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, _raw, key} = ApiKeys.create_api_key(org, "recon", ["analyze"])

    %{org: org, api_key: key}
  end

  describe "a clean ledger reconciles" do
    test "no usage at all is reconciled" do
      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 0
      assert report.drift_credits == 0
      assert Reconciliation.reconciled?()
    end

    test "recorded usage reconciles exactly", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 10, 2)

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 0
      assert report.drift_credits == 0
      # 10 hits * 5 + 2 misses * 50 = 150
      assert report.expected_credits == 150
      assert report.debited_credits == 150
    end

    test "repeated usage on one row still reconciles", %{org: org, api_key: key} do
      for _ <- 1..5, do: {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 1)

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 0
      assert report.expected_credits == report.debited_credits
      assert report.expected_credits == 5 * 55
    end

    test "several orgs reconcile independently", %{org: org, api_key: key} do
      {:ok, other} =
        ApiKeys.find_or_create_org("Recon Other #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _raw, other_key} = ApiKeys.create_api_key(other, "recon", ["analyze"])

      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 3, 0)
      {:ok, _} = UsageTracker.record_usage(other.id, other_key.id, 0, 2)

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 0
      assert report.expected_credits == 15 + 100
    end
  end

  describe "drift is detected" do
    test "a usage row with no debit at all is drift", %{org: org, api_key: key} do
      # The shape this check exists for: usage recorded, nothing charged.
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 4, 1)

      Repo.delete_all(from_debits_for(usage.id))

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 1
      # 4 * 5 + 1 * 50 = 70
      assert report.drift_credits == 70
      refute Reconciliation.reconciled?()
    end

    test "a partially debited row is drift", %{org: org, api_key: key} do
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 0, 2)

      # Halve the debit, as a botched correction would.
      [entry] = Repo.all(from_debits_for(usage.id))
      {:ok, _} = entry |> Ecto.Changeset.change(delta: -50) |> Repo.update()

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 1
      assert report.drift_credits == 50
    end

    test "an over-debited row drifts negative", %{org: org, api_key: key} do
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      [entry] = Repo.all(from_debits_for(usage.id))
      {:ok, _} = entry |> Ecto.Changeset.change(delta: -500) |> Repo.update()

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 1
      assert report.drift_credits == 5 - 500
    end

    test "drifting_rows names the row and the amount", %{org: org, api_key: key} do
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 2, 0)
      Repo.delete_all(from_debits_for(usage.id))

      assert [row] = Reconciliation.drifting_rows()

      assert row.usage_id == usage.id
      assert row.org_id == org.id
      assert row.drift == 10
    end

    test "only the drifting row is reported", %{org: org, api_key: key} do
      {:ok, clean} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      {:ok, other} =
        ApiKeys.find_or_create_org("Recon Mixed #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _raw, other_key} = ApiKeys.create_api_key(other, "recon", ["analyze"])
      {:ok, broken} = UsageTracker.record_usage(other.id, other_key.id, 0, 1)
      Repo.delete_all(from_debits_for(broken.id))

      assert [row] = Reconciliation.drifting_rows()
      assert row.usage_id == broken.id
      refute row.usage_id == clean.id
    end
  end

  describe "pre-ledger usage is not drift" do
    test "a usage row older than the first credit entry is excluded", %{org: org, api_key: key} do
      # Rows recorded before the ledger existed have no debits and never will.
      # Counting them as drift would leave the check permanently non-zero,
      # which is the same as having no check.
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 5, 0)
      Repo.delete_all(from_debits_for(usage.id))

      # Push it before the ledger's first entry.
      {:ok, _} =
        usage
        |> Ecto.Changeset.change(updated_at: ~N[2020-01-01 00:00:00])
        |> Repo.update()

      # A debit has to exist somewhere for a boundary to exist, and it must be
      # another org's -- recording usage for this one would land on the same
      # period row and give it the debit the test is asserting it lacks.
      {:ok, other} =
        ApiKeys.find_or_create_org("Recon Boundary #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _raw, other_key} = ApiKeys.create_api_key(other, "recon", ["analyze"])
      {:ok, _} = UsageTracker.record_usage(other.id, other_key.id, 1, 0)

      report = Reconciliation.usage_vs_credits()

      assert report.pre_ledger_rows == 1
      assert report.drifting_rows == 0
      assert Reconciliation.reconciled?()
    end

    test "an old row that WAS debited still reconciles", %{org: org, api_key: key} do
      # Only rows with no debits count as pre-ledger. An old row carrying
      # debits is a real reconciliation subject.
      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 2, 0)

      {:ok, _} =
        usage
        |> Ecto.Changeset.change(updated_at: ~N[2020-01-01 00:00:00])
        |> Repo.update()

      report = Reconciliation.usage_vs_credits()

      assert report.pre_ledger_rows == 0
      assert report.drifting_rows == 0
    end
  end

  describe "manual adjustments are not usage" do
    test "a grant does not create drift", %{org: org, api_key: key} do
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)
      {:ok, _} = Lei.Credits.grant(org.id, 15_000, "purchase:stripe", external_ref: "pi_recon")
      {:ok, _} = Lei.Credits.grant(org.id, 20, "adjustment:manual")

      report = Reconciliation.usage_vs_credits()

      assert report.drifting_rows == 0
      assert report.debited_credits == 5
    end
  end

  describe "an unknown ledger start does not excuse everything" do
    test "drift is still reported when nothing has ever been debited", %{org: org, api_key: key} do
      # An earlier version of this check excused every row when it could not
      # determine a start, and reported clean having reconciled nothing.
      #
      # The boundary is now the first debit, so "no debits at all" is exactly
      # the case where it cannot be determined -- and every row must still be
      # reconciled rather than excused.
      {:ok, _usage} = UsageTracker.record_usage(org.id, key.id, 3, 0)

      Repo.delete_all(from(e in CreditEntry, where: e.reason == "debit:analysis"))

      report = Reconciliation.usage_vs_credits()

      assert report.ledger_started_at == nil
      assert report.pre_ledger_rows == 0, "an unknown start must exclude nothing, not everything"
      assert report.drifting_rows == 1
      assert report.drift_credits == 15
    end
  end

  describe "the check can fail" do
    test "reconciled? is not simply always true", %{org: org, api_key: key} do
      # A check that cannot report failure is not a check. This asserts the
      # negative case is reachable, which several checks in this repo were not.
      assert Reconciliation.reconciled?()

      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 1, 0)
      Repo.delete_all(from_debits_for(usage.id))

      refute Reconciliation.reconciled?()
    end
  end

  defp from_debits_for(usage_id) do
    from(e in CreditEntry,
      where: e.reason == "debit:analysis",
      where: fragment("(?->>'analysis_usage_id')::bigint", e.metadata) == ^usage_id
    )
  end
end
