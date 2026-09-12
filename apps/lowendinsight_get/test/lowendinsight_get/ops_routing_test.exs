defmodule LowendinsightGet.OpsRoutingTest do
  @moduledoc """
  Integration tests for the ops and provisioning routes as mounted on
  LowendinsightGet.Endpoint.

  Every route here is defined in Lei.Web.Router and was unreachable in
  production: /healthz, /readyz and /metrics returned 404 because they were
  absent from @auth_paths, and /v1/health and /v1/orgs returned 401 because
  LowendinsightGet.Auth gates any path containing "/v1".

  Tests that exercise Lei.Web.Router directly cannot catch this. These drive
  the endpoint, which is the thing actually deployed.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LowendinsightGet.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp get(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  defp admin_key do
    {:ok, org} =
      ApiKeys.find_or_create_org("Ops Routing Org #{System.unique_integer([:positive])}",
        tier: "free",
        status: "active"
      )

    {:ok, raw_key, _} = ApiKeys.create_api_key(org, "ops-test", ["admin", "analyze"])
    {org, raw_key}
  end

  describe "unauthenticated platform probes" do
    test "GET /healthz returns 200" do
      conn = get("/healthz")

      assert conn.status == 200
      assert Poison.decode!(conn.resp_body)["status"] == "ok"
    end

    test "GET /readyz reports dependency checks" do
      conn = get("/readyz")

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["checks"]["database"] == "ok"
    end

    test "GET /metrics returns Prometheus text" do
      conn = get("/metrics")

      assert conn.status == 200
      assert conn.resp_body =~ "beam_memory_bytes"
      assert conn.resp_body =~ "lei_cache_entries_total"
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
    end

    # /v1/health is under the /v1 prefix, which LowendinsightGet.Auth otherwise
    # gates wholesale. Platform probes carry no credentials, so this must be
    # reachable without an Authorization header.
    test "GET /v1/health returns 200 with no Authorization header" do
      conn = get("/v1/health")

      assert conn.status == 200
    end
  end

  describe "/v1/orgs provisioning" do
    test "an unknown slug reaches the router rather than the endpoint catch-all" do
      {_org, key} = admin_key()

      conn = get("/v1/orgs/definitely-not-a-real-org/keys", [{"authorization", "Bearer #{key}"}])

      # Both a routed miss and an unroutable path return 404, so the body is
      # what distinguishes them. The endpoint catch-all says
      # "UUID not provided or found."
      assert conn.status == 404
      assert Poison.decode!(conn.resp_body)["error"] == "org not found"
    end

    test "lists keys for a real org" do
      {org, key} = admin_key()

      conn = get("/v1/orgs/#{org.slug}/keys", [{"authorization", "Bearer #{key}"}])

      assert conn.status == 200
      keys = Poison.decode!(conn.resp_body)["keys"]
      assert is_list(keys)
      assert Enum.any?(keys, &(&1["name"] == "ops-test"))
    end

    test "still requires authentication" do
      conn = get("/v1/orgs/some-org/keys")

      assert conn.status == 401
    end
  end

  describe "regression guard" do
    # The original defect: routes existed in Lei.Web.Router but were never
    # forwarded, so they hit the endpoint's own catch-all.
    test "no ops route falls through to the endpoint catch-all" do
      # /v1/credits is here because a route that exists in Lei.Web.Router but
      # is missing from @auth_paths returns 404 in production while every test
      # of the route itself passes -- #69 shipped eight of those at once.
      for path <- ["/healthz", "/readyz", "/metrics", "/v1/health", "/v1/credits"] do
        conn = get(path)

        refute conn.status == 404,
               "#{path} returned 404 — it is not being forwarded to Lei.Web.Router"

        refute conn.resp_body =~ "UUID not provided or found",
               "#{path} hit the endpoint catch-all instead of the router"
      end
    end
  end
end
