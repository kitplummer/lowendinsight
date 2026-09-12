defmodule Lei.MeterReportingTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Mox

  alias Lei.{ApiKeys, MeterReport, Reconciliation, Repo, UsageTracker}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Meter Org #{System.unique_integer([:positive])}",
        tier: "pro",
        status: "active"
      )

    {:ok, org} =
      org
      |> Ecto.Changeset.change(
        stripe_customer_id: "cus_meter_#{System.unique_integer([:positive])}"
      )
      |> Repo.update()

    {:ok, _raw, key} = ApiKeys.create_api_key(org, "meter", ["analyze"])

    %{org: org, api_key: key}
  end

  defp reports(org_id) do
    Repo.all(from(r in MeterReport, where: r.org_id == ^org_id, order_by: r.id))
  end

  describe "a successful meter report is recorded" do
    test "records status ok with the units sent", %{org: org, api_key: key} do
      stub(Lei.StripeMock, :report_meter_event, fn _cus, _units, _ts, _id -> {:ok, %{}} end)

      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 10, 0)

      assert [report] = reports(org.id)
      assert report.status == "ok"
      # 10 hits at 0.5c = 5c = 50 tenth-cent units
      assert report.units == 50
      assert report.analysis_usage_id == usage.id
      assert is_nil(report.error)
    end
  end

  describe "a failed meter report is recorded" do
    test "records status failed and the reason", %{org: org, api_key: key} do
      # This is the whole point. Previously the call failed, a warning was
      # logged, the return value was discarded, and nothing recorded that the
      # customer had consumed usage they were never billed for.
      stub(Lei.StripeMock, :report_meter_event, fn _cus, _units, _ts, _id ->
        {:error, :timeout}
      end)

      {:ok, _usage} = UsageTracker.record_usage(org.id, key.id, 0, 1)

      assert [report] = reports(org.id)
      assert report.status == "failed"
      assert report.error =~ "timeout"
    end

    test "a failed report does not fail the usage write", %{org: org, api_key: key} do
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:error, :boom} end)

      assert {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 1, 0)
      assert usage.cache_hits == 1
      assert Lei.Credits.balance(org.id) == -5
    end
  end

  describe "orgs that are not metered" do
    test "a free org produces no meter report" do
      {:ok, free} =
        ApiKeys.find_or_create_org("Meter Free #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _raw, key} = ApiKeys.create_api_key(free, "meter", ["analyze"])
      {:ok, _} = UsageTracker.record_usage(free.id, key.id, 5, 0)

      assert reports(free.id) == []
    end

    test "a pro org with no stripe customer produces none" do
      {:ok, pro} =
        ApiKeys.find_or_create_org("Meter NoCus #{System.unique_integer([:positive])}",
          tier: "pro",
          status: "active"
        )

      {:ok, _raw, key} = ApiKeys.create_api_key(pro, "meter", ["analyze"])
      {:ok, _} = UsageTracker.record_usage(pro.id, key.id, 5, 0)

      assert reports(pro.id) == []
    end
  end

  describe "stripe_reporting/0" do
    test "counts a successful report as reported", %{org: org, api_key: key} do
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:ok, %{}} end)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 2, 0)

      report = Reconciliation.stripe_reporting()

      assert report.metered_orgs >= 1
      assert report.reported == 1
      assert report.failed == 0
      assert report.unreported == 0
    end

    test "counts a failed report as failed, not unreported", %{org: org, api_key: key} do
      # They need different responses: failed means we know and can replay;
      # unreported means we do not know it happened.
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:error, :nope} end)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 0, 1)

      report = Reconciliation.stripe_reporting()

      assert report.failed == 1
      assert report.unreported == 0
    end

    test "a debit with no meter report at all is unreported", %{org: org, api_key: key} do
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:ok, %{}} end)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 0, 2)

      # As if the process died between committing the debit and calling Stripe.
      Repo.delete_all(from(r in MeterReport, where: r.org_id == ^org.id))

      report = Reconciliation.stripe_reporting()

      assert report.unreported == 1
      assert report.unreported_credits == 100
    end

    test "free orgs are not counted as unreported" do
      # They are never metered, so a debit without a meter report is correct
      # and must not be reported as a gap.
      {:ok, free} =
        ApiKeys.find_or_create_org("Meter Free2 #{System.unique_integer([:positive])}",
          status: "active"
        )

      {:ok, _raw, key} = ApiKeys.create_api_key(free, "meter", ["analyze"])
      {:ok, _} = UsageTracker.record_usage(free.id, key.id, 3, 0)

      report = Reconciliation.stripe_reporting()

      assert report.unreported == 0
    end

    test "reports zero on an empty system" do
      assert %{reported: 0, failed: 0, unreported: 0} = Reconciliation.stripe_reporting()
    end
  end

  describe "the record is append-only alongside the ledger" do
    test "a duplicate identifier does not create a second row", %{org: org, api_key: key} do
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:ok, %{}} end)

      {:ok, usage} = UsageTracker.record_usage(org.id, key.id, 1, 0)
      [existing] = reports(org.id)

      {:error, changeset} =
        %MeterReport{}
        |> MeterReport.changeset(%{
          org_id: org.id,
          analysis_usage_id: usage.id,
          identifier: existing.identifier,
          units: existing.units,
          status: "ok"
        })
        |> Repo.insert()

      assert Keyword.has_key?(changeset.errors, :identifier)
      assert length(reports(org.id)) == 1
    end

    test "credit entries are not modified by metering", %{org: org, api_key: key} do
      # The ledger stays append-only: the outcome is recorded alongside it, not
      # stamped onto the debit afterwards.
      stub(Lei.StripeMock, :report_meter_event, fn _, _, _, _ -> {:error, :nope} end)
      {:ok, _} = UsageTracker.record_usage(org.id, key.id, 1, 0)

      [entry] = Repo.all(from(e in Lei.CreditEntry, where: e.org_id == ^org.id))

      refute Map.has_key?(entry, :updated_at)
      assert entry.reason == "debit:analysis"
    end
  end
end
