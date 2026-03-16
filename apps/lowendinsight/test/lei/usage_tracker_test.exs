defmodule Lei.UsageTrackerTest do
  use ExUnit.Case, async: false
  alias Lei.{UsageTracker, ApiKeys}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} = ApiKeys.find_or_create_org("Usage Test Org", tier: "free", status: "active")
    {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test-key", ["analyze"])

    %{org: org, api_key: api_key}
  end

  describe "calculate_cost/2" do
    test "calculates cost for hits only" do
      cost = UsageTracker.calculate_cost(100, 0)
      assert Decimal.equal?(cost, Decimal.new("50.0"))
    end

    test "calculates cost for misses only" do
      cost = UsageTracker.calculate_cost(0, 10)
      assert Decimal.equal?(cost, Decimal.new("50.0"))
    end

    test "calculates mixed cost per ADR-001 rates" do
      # 1100 hits * 0.5 + 100 misses * 5.0 = 550 + 500 = 1050
      cost = UsageTracker.calculate_cost(1100, 100)
      assert Decimal.equal?(cost, Decimal.new("1050.0"))
    end

    test "zero hits and misses returns zero" do
      cost = UsageTracker.calculate_cost(0, 0)
      assert Decimal.equal?(cost, Decimal.new("0.0"))
    end
  end

  describe "record_usage/4" do
    test "creates new usage record for current period", %{org: org, api_key: api_key} do
      assert {:ok, usage} = UsageTracker.record_usage(org.id, api_key.id, 10, 2)
      assert usage.cache_hits == 10
      assert usage.cache_misses == 2
      assert Decimal.equal?(usage.total_cost_cents, Decimal.new("15.0"))
      assert usage.period_start == UsageTracker.current_period_start()
    end

    test "upserts — increments existing record", %{org: org, api_key: api_key} do
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 10, 2)
      {:ok, updated} = UsageTracker.record_usage(org.id, api_key.id, 5, 3)

      assert updated.cache_hits == 15
      assert updated.cache_misses == 5
      # 10*0.5 + 2*5 = 15.0, then 5*0.5 + 3*5 = 17.5, total = 32.5
      assert Decimal.equal?(updated.total_cost_cents, Decimal.new("32.5"))
    end

    test "accepts nil api_key_id", %{org: org} do
      assert {:ok, usage} = UsageTracker.record_usage(org.id, nil, 1, 0)
      assert usage.cache_hits == 1
    end
  end

  describe "get_current_usage/1" do
    test "returns zeros when no usage recorded", %{org: org} do
      usage = UsageTracker.get_current_usage(org.id)
      assert usage.cache_hits == 0
      assert usage.cache_misses == 0
      assert Decimal.equal?(usage.total_cost_cents, Decimal.new(0))
    end

    test "returns current period usage", %{org: org, api_key: api_key} do
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 50, 10)
      usage = UsageTracker.get_current_usage(org.id)

      assert usage.cache_hits == 50
      assert usage.cache_misses == 10
      assert usage.period_start == UsageTracker.current_period_start()
    end
  end

  describe "check_free_tier_quota/1" do
    test "returns remaining quota for free tier", %{org: org} do
      assert {:ok, 200} = UsageTracker.check_free_tier_quota(org.id)
    end

    test "returns quota_exceeded when limit reached", %{org: org, api_key: api_key} do
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 150, 50)

      assert {:error, :quota_exceeded, %{used: 200, limit: 200}} =
               UsageTracker.check_free_tier_quota(org.id)
    end

    test "returns remaining after partial usage", %{org: org, api_key: api_key} do
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 30, 20)
      assert {:ok, 150} = UsageTracker.check_free_tier_quota(org.id)
    end

    test "returns unlimited for pro tier" do
      {:ok, pro_org} = ApiKeys.find_or_create_org("Pro Org", tier: "pro", status: "active")
      assert {:ok, :unlimited} = UsageTracker.check_free_tier_quota(pro_org.id)
    end

    test "returns error for non-existent org" do
      assert {:error, :org_not_found} = UsageTracker.check_free_tier_quota(999_999)
    end
  end

  describe "current_period_start/0" do
    test "returns first of current month" do
      today = Date.utc_today()
      assert UsageTracker.current_period_start() == Date.new!(today.year, today.month, 1)
    end
  end

  describe "record_usage_async/4" do
    test "fires without blocking", %{org: org, api_key: api_key} do
      assert {:ok, _pid} = UsageTracker.record_usage_async(org.id, api_key.id, 1, 0)
      # Give the async task a moment to complete
      Process.sleep(100)
      usage = UsageTracker.get_current_usage(org.id)
      assert usage.cache_hits == 1
    end
  end
end
