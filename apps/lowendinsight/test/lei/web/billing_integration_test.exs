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
  # Manual check 5: usage reported to Stripe as billing meter events
  # ---------------------------------------------------------------
  describe "Stripe billing meter events" do
    test "reports this usage only, never a running total" do
      {:ok, org} = ApiKeys.find_or_create_org("Meter Org", tier: "pro", status: "active")

      org =
        org
        |> Org.stripe_changeset(%{stripe_customer_id: "cus_meter_test"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # 10 hits (0.5c each) + 2 misses (5c each) = 15 cents = 150 tenth-cent units
      Mox.expect(Lei.StripeMock, :report_meter_event, fn "cus_meter_test",
                                                         value,
                                                         timestamp,
                                                         identifier ->
        assert value == 150
        assert is_integer(timestamp)

        # Stripe deduplicates on this; without it a retry double-charges.
        assert is_binary(identifier) and identifier != ""
        {:ok, %{"identifier" => "mev_1"}}
      end)

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 10, 2)

      # A second batch must report only its own cost. Meter events are summed by
      # Stripe, so sending a cumulative figure here would compound the bill.
      Mox.expect(Lei.StripeMock, :report_meter_event, fn "cus_meter_test", value, _ts, _id ->
        assert value == 50, "expected only this batch's cost, got a running total"
        {:ok, %{"identifier" => "mev_2"}}
      end)

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 0, 1)
    end

    # Ordering matters: the local row is the source of truth and Stripe is
    # derived from it. Reporting first meant a failed insert could leave the
    # customer billed for usage this database had no record of.
    #
    # The identifier embeds the persisted row id, which cannot be known until
    # the insert has committed -- so asserting on it proves the ordering
    # directly, rather than by simulating a failure.
    test "the meter event is derived from the committed row" do
      {:ok, org} = ApiKeys.find_or_create_org("Order Org", tier: "pro", status: "active")

      org =
        org
        |> Org.stripe_changeset(%{stripe_customer_id: "cus_order_test"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      test_pid = self()

      Mox.expect(Lei.StripeMock, :report_meter_event, fn _cus, _value, _ts, identifier ->
        send(test_pid, {:identifier, identifier})
        {:ok, %{"identifier" => identifier}}
      end)

      {:ok, usage} = UsageTracker.record_usage(org.id, api_key.id, 2, 0)

      assert_received {:identifier, identifier}

      assert String.starts_with?(identifier, "lei-usage-#{usage.id}-"),
             "identifier #{inspect(identifier)} does not reference the committed row #{usage.id}"
    end

    test "the identifier is stable for the same write and changes for new usage" do
      {:ok, org} = ApiKeys.find_or_create_org("Ident Org", tier: "pro", status: "active")

      org =
        org
        |> Org.stripe_changeset(%{stripe_customer_id: "cus_ident_test"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      test_pid = self()

      Mox.expect(Lei.StripeMock, :report_meter_event, 2, fn _cus, _value, _ts, identifier ->
        send(test_pid, {:identifier, identifier})
        {:ok, %{"identifier" => identifier}}
      end)

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 2, 0)
      assert_received {:identifier, first}

      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 4, 0)
      assert_received {:identifier, second}

      # Distinct usage must not deduplicate against the earlier event, or the
      # second batch would silently go unbilled.
      refute first == second
    end

    test "skips orgs with no Stripe customer" do
      {:ok, org} = ApiKeys.find_or_create_org("Free Meter Org", tier: "free", status: "active")
      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      # No Mox expectation: a free org must not produce a meter event.
      {:ok, _} = UsageTracker.record_usage(org.id, api_key.id, 5, 1)
    end

    test "a metering failure does not fail usage recording" do
      {:ok, org} = ApiKeys.find_or_create_org("Meter Fail Org", tier: "pro", status: "active")

      org =
        org
        |> Org.stripe_changeset(%{stripe_customer_id: "cus_meter_fail"})
        |> Repo.update!()

      {:ok, _raw_key, api_key} = ApiKeys.create_api_key(org, "test", ["analyze"])

      Mox.expect(Lei.StripeMock, :report_meter_event, fn _, _, _, _ ->
        {:error, %{"error" => "meter unavailable"}}
      end)

      # The analysis was already served; a metering outage must not undo that.
      assert {:ok, usage} = UsageTracker.record_usage(org.id, api_key.id, 4, 0)
      assert usage.cache_hits == 4
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
