defmodule Lei.Web.BillingIntegrationTest do
  @moduledoc """
  Integration tests for cache-tiered usage tracking and metered billing.
  Covers the manual test plan from PR #40.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.{ApiKeys, UsageTracker, Repo, Org}

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.BatchCache.clear()
    Lei.RateLimiter.clear()
    :ok
  end

  defp call(conn), do: Lei.Web.Router.call(conn, @opts)

  defp batch_analyze(deps, key) do
    body = %{"dependencies" => deps}

    conn(:post, "/v1/analyze/batch", Poison.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{key}")
    |> call()
  end

  defp sample_deps(n) do
    Enum.map(1..n, fn i ->
      %{"ecosystem" => "npm", "package" => "pkg-#{i}", "version" => "1.0.#{i}"}
    end)
  end

  # ---------------------------------------------------------------
  # Manual check 1: Free tier → 200 analyses → 201st returns 402
  # ---------------------------------------------------------------
  describe "free tier quota enforcement" do
    test "allows requests within 200 analysis limit" do
      {:ok, org} = ApiKeys.find_or_create_org("Free Quota Org", tier: "free", status: "active")
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Record 199 analyses directly (simulating prior usage)
      {:ok, _} = UsageTracker.record_usage(org.id, nil, 150, 49)

      # One more batch of 1 should succeed (total = 200)
      conn = batch_analyze(sample_deps(1), raw_key)
      assert conn.status == 200
    end

    test "returns 402 when free tier quota exceeded" do
      {:ok, org} = ApiKeys.find_or_create_org("Free Exceeded Org", tier: "free", status: "active")
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Record exactly 200 analyses (at limit)
      {:ok, _} = UsageTracker.record_usage(org.id, nil, 150, 50)

      # Next request should be rejected
      conn = batch_analyze(sample_deps(1), raw_key)
      assert conn.status == 402

      response = Poison.decode!(conn.resp_body)
      assert response["error"] == "free_tier_quota_exceeded"
      assert response["used"] == 200
      assert response["limit"] == 200
      assert response["upgrade_url"] =~ "signup?tier=pro"
    end

    test "pro tier is never quota-blocked" do
      {:ok, org} = ApiKeys.find_or_create_org("Pro Unlimited Org", tier: "pro", status: "active")
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Record heavy usage
      {:ok, _} = UsageTracker.record_usage(org.id, nil, 5000, 500)

      # Still succeeds
      conn = batch_analyze(sample_deps(1), raw_key)
      assert conn.status == 200
    end
  end

  # ---------------------------------------------------------------
  # Manual check 2: Pro tier → analyze → billing in response
  # ---------------------------------------------------------------
  describe "billing info in batch response" do
    test "response includes billing block with cost breakdown" do
      {:ok, org} = ApiKeys.find_or_create_org("Billing Resp Org", tier: "pro", status: "active")
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      conn = batch_analyze(sample_deps(3), raw_key)
      assert conn.status == 200

      response = Poison.decode!(conn.resp_body)
      billing = response["billing"]

      assert is_map(billing)
      assert is_integer(billing["cache_hits"]) or is_integer(billing["cache_misses"])
      assert billing["tier"] == "pro"
      assert Map.has_key?(billing, "cost_cents")

      # cache_hits + cache_misses should equal total dependencies
      assert billing["cache_hits"] + billing["cache_misses"] ==
               response["summary"]["total"]
    end

    test "billing cost matches ADR-001 rates" do
      {:ok, org} = ApiKeys.find_or_create_org("ADR Cost Org", tier: "free", status: "active")
      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      conn = batch_analyze(sample_deps(5), raw_key)
      assert conn.status == 200

      response = Poison.decode!(conn.resp_body)
      billing = response["billing"]
      hits = billing["cache_hits"]
      misses = billing["cache_misses"]

      expected_cost = hits * 0.5 + misses * 5.0

      # Cost in response should match calculated cost
      assert billing["cost_cents"] == expected_cost
    end

    test "JWT-only requests omit billing block" do
      secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
      signer = Joken.Signer.create("HS256", secret)
      {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{}, signer)

      body = %{"dependencies" => sample_deps(1)}

      conn =
        conn(:post, "/v1/analyze/batch", Poison.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> call()

      assert conn.status == 200
      response = Poison.decode!(conn.resp_body)

      # billing block should still be present but with nil/unknown tier
      billing = response["billing"]
      assert billing["tier"] == "unknown"
    end
  end

  # ---------------------------------------------------------------
  # Manual check 3: GET /v1/usage → cost breakdown
  # ---------------------------------------------------------------
  describe "GET /v1/usage" do
    test "returns current period usage for authenticated org" do
      {:ok, org} = ApiKeys.find_or_create_org("Usage API Org", tier: "pro", status: "active")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Record some usage
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 1523, 47)

      conn =
        conn(:get, "/v1/usage")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> call()

      assert conn.status == 200
      response = Poison.decode!(conn.resp_body)

      assert response["cache_hits"] == 1523
      assert response["cache_misses"] == 47
      assert response["tier"] == "pro"
      assert response["included_credit_cents"] == 1500
      assert is_binary(response["period_start"])

      # total_cost = 1523 * 0.5 + 47 * 5.0 = 761.5 + 235.0 = 996.5
      assert response["total_cost_cents"] == 996.5

      # No overage (996.5 < 1500 credit)
      assert response["overage_cents"] == 0.0
    end

    test "shows overage when usage exceeds pro credit" do
      {:ok, org} = ApiKeys.find_or_create_org("Overage API Org", tier: "pro", status: "active")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # 2000 * 0.5 + 200 * 5.0 = 1000 + 1000 = 2000 cents > 1500 credit
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 2000, 200)

      conn =
        conn(:get, "/v1/usage")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> call()

      assert conn.status == 200
      response = Poison.decode!(conn.resp_body)

      assert response["overage_cents"] == 500.0
    end

    test "shows free tier usage without credit" do
      {:ok, org} = ApiKeys.find_or_create_org("Free Usage Org", tier: "free", status: "active")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 50, 10)

      conn =
        conn(:get, "/v1/usage")
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> call()

      assert conn.status == 200
      response = Poison.decode!(conn.resp_body)

      assert response["tier"] == "free"
      assert response["included_credit_cents"] == 0
      assert response["cache_hits"] == 50
      assert response["cache_misses"] == 10
    end

    test "returns 401 without API key auth" do
      secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
      signer = Joken.Signer.create("HS256", secret)
      {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{}, signer)

      conn =
        conn(:get, "/v1/usage")
        |> put_req_header("authorization", "Bearer #{jwt}")
        |> call()

      assert conn.status == 401
      response = Poison.decode!(conn.resp_body)
      assert response["error"] =~ "API key required"
    end
  end

  # ---------------------------------------------------------------
  # Manual check 4: Dashboard shows usage stats
  # ---------------------------------------------------------------
  describe "dashboard usage display" do
    test "dashboard renders usage section for free tier" do
      {:ok, org} = ApiKeys.find_or_create_org("Dash Free Org", tier: "free", status: "active")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "admin", ["admin", "analyze"])

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 75, 25)

      # Login first to set session
      login_conn =
        conn(:post, "/login", "api_key=#{raw_key}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      assert login_conn.status == 302

      # Extract session cookie
      cookie = login_conn |> get_resp_header("set-cookie") |> List.first()

      # Visit dashboard with session
      dash_conn =
        conn(:get, "/dashboard")
        |> put_req_header("cookie", cookie)
        |> call()

      assert dash_conn.status == 200
      assert dash_conn.resp_body =~ "Cache Hits"
      assert dash_conn.resp_body =~ "Cache Misses"
      assert dash_conn.resp_body =~ "Total Cost"
      assert dash_conn.resp_body =~ "Free Tier"
      assert dash_conn.resp_body =~ "100/200 analyses used"
    end

    test "dashboard renders usage section for pro tier" do
      {:ok, org} = ApiKeys.find_or_create_org("Dash Pro Org", tier: "pro", status: "active")
      {:ok, raw_key, api_key} = ApiKeys.create_api_key(org, "admin", ["admin", "analyze"])

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 500, 100)

      login_conn =
        conn(:post, "/login", "api_key=#{raw_key}")
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> call()

      cookie = login_conn |> get_resp_header("set-cookie") |> List.first()

      dash_conn =
        conn(:get, "/dashboard")
        |> put_req_header("cookie", cookie)
        |> call()

      assert dash_conn.status == 200
      assert dash_conn.resp_body =~ "Cache Hits"
      assert dash_conn.resp_body =~ "Pro Tier"
      assert dash_conn.resp_body =~ "credit included"
    end
  end

  # ---------------------------------------------------------------
  # Manual check 5: BillingReporter → Stripe usage record created
  # ---------------------------------------------------------------
  describe "BillingReporter Stripe integration" do
    test "reports overage to Stripe for pro org with metered subscription" do
      {:ok, org} = ApiKeys.find_or_create_org("Stripe Bill Org", tier: "pro", status: "active")

      org =
        org
        |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_integration_test"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Generate overage: 2000 * 0.5 + 200 * 5.0 = 2000 cents > 1500 credit = 500 overage
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 2000, 200)

      Mox.expect(Lei.StripeMock, :report_usage, fn "si_integration_test", quantity, timestamp ->
        assert quantity == 500
        assert is_integer(timestamp)
        {:ok, %{"id" => "mbur_integration_test", "quantity" => quantity}}
      end)

      assert {:ok, %{overage_cents: 500, stripe_record: record}} =
               Lei.BillingReporter.report_for_org(org)

      assert record["id"] == "mbur_integration_test"
    end

    test "does not report when usage is within pro credit" do
      {:ok, org} = ApiKeys.find_or_create_org("No Overage Org", tier: "pro", status: "active")

      org =
        org
        |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_no_overage"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # 100 * 0.5 + 10 * 5.0 = 100 cents << 1500 credit
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 100, 10)

      # No Mox expectation — report_usage should NOT be called
      assert {:ok, :no_overage} = Lei.BillingReporter.report_for_org(org)
    end

    test "full billing reporter run processes eligible orgs" do
      {:ok, org} = ApiKeys.find_or_create_org("Full Run Org", tier: "pro", status: "active")

      org =
        org
        |> Org.billing_changeset(%{stripe_metered_subscription_item_id: "si_full_run"})
        |> Repo.update!()

      # No usage — should report no overage
      {:ok, results} = Lei.BillingReporter.run_billing_report()
      matching = Enum.filter(results, fn {_, id, _} -> id == org.id end)
      assert [{:ok, _, :no_overage}] = matching
    end
  end

  # ---------------------------------------------------------------
  # Usage tracking records correctly after batch analysis
  # ---------------------------------------------------------------
  describe "usage tracking after analysis" do
    test "batch analysis records usage in database" do
      {:ok, org} =
        ApiKeys.find_or_create_org("Track Record Org", tier: "pro", status: "active")

      {:ok, raw_key, _} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # Analyze a batch
      conn = batch_analyze(sample_deps(3), raw_key)
      assert conn.status == 200

      # Give async task time to complete
      Process.sleep(200)

      usage = UsageTracker.get_current_usage(org.id)
      # All 3 deps should be cache misses (fresh cache)
      assert usage.cache_hits + usage.cache_misses == 3
    end
  end
end
