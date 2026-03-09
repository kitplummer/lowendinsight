defmodule Lei.BillingReporterTest do
  use ExUnit.Case, async: false
  alias Lei.{BillingReporter, ApiKeys, UsageTracker, Repo, Org}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  describe "report_for_org/1" do
    test "returns no_overage when usage is below credit" do
      {:ok, org} = ApiKeys.find_or_create_org("Low Usage Pro", tier: "pro", status: "active")

      org =
        org
        |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_test_123"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 100, 10)

      # 100 * 0.5 + 10 * 5.0 = 100 cents, well below 1500 credit
      assert {:ok, :no_overage} = BillingReporter.report_for_org(org)
    end

    test "reports overage to Stripe when usage exceeds credit" do
      {:ok, org} = ApiKeys.find_or_create_org("High Usage Pro", tier: "pro", status: "active")

      org =
        org
        |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_test_456"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # 2000 * 0.5 + 200 * 5.0 = 1000 + 1000 = 2000 cents > 1500 credit
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 2000, 200)

      # StripeMock is configured in test.exs — Mox expects
      Mox.expect(Lei.StripeMock, :report_usage, fn "si_test_456", quantity, _ts ->
        # Overage = 2000 - 1500 = 500 cents
        assert quantity == 500
        {:ok, %{"id" => "mbur_test"}}
      end)

      assert {:ok, %{overage_cents: 500, stripe_record: %{"id" => "mbur_test"}}} =
               BillingReporter.report_for_org(org)
    end
  end

  describe "run_billing_report/0" do
    test "processes all eligible pro orgs" do
      # Create a pro org with metered subscription
      {:ok, org} = ApiKeys.find_or_create_org("Report All Pro", tier: "pro", status: "active")

      org
      |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_report_all"})
      |> Repo.update!()

      # No usage recorded, so no overage
      assert {:ok, results} = BillingReporter.run_billing_report()
      # Should have at least one result (our org), all no_overage
      matching = Enum.filter(results, fn {_, id, _} -> id == org.id end)
      assert [{:ok, _, :no_overage}] = matching
    end

    test "skips free tier orgs" do
      {:ok, free_org} =
        ApiKeys.find_or_create_org("Free Skip Org", tier: "free", status: "active")

      assert {:ok, results} = BillingReporter.run_billing_report()
      # Free org should not appear in results
      refute Enum.any?(results, fn {_, id, _} -> id == free_org.id end)
    end
  end

  describe "start_link/1" do
    test "starts GenServer without timer for testing" do
      assert {:ok, pid} = BillingReporter.start_link(name: :test_reporter, start_timer: false)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "report_now triggers immediate run" do
      {:ok, pid} = BillingReporter.start_link(name: :test_reporter_now, start_timer: false)
      assert {:ok, _results} = BillingReporter.report_now(:test_reporter_now)
      GenServer.stop(pid)
    end
  end
end
