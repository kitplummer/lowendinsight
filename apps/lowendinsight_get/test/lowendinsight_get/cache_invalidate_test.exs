defmodule LowendinsightGet.CacheInvalidateTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LowendinsightGet.Endpoint.init([])
  @url "https://github.com/kitplummer/canary-test-repo"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Cache Inv #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, admin_key, _} = ApiKeys.create_api_key(org, "admin", ["admin"])
    {:ok, plain_key, _} = ApiKeys.create_api_key(org, "plain", ["analyze"])

    %{admin_key: admin_key, plain_key: plain_key}
  end

  defp invalidate(key, payload) do
    conn = conn(:post, "/v1/cache/invalidate", Poison.encode!(payload))

    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if key, do: put_req_header(conn, "authorization", "Bearer #{key}"), else: conn

    LowendinsightGet.Endpoint.call(conn, @opts)
  end

  describe "authorisation" do
    test "requires a key" do
      conn = invalidate(nil, %{url: @url})

      assert conn.status == 401
    end

    test "requires admin scope", %{plain_key: key} do
      # Invalidation forces real work on the next request. On an endpoint any
      # key could call, it is a lever for making every request expensive.
      conn = invalidate(key, %{url: @url})

      assert conn.status == 403
      assert Poison.decode!(conn.resp_body)["error"] == "insufficient scope"
    end

    test "an admin key is accepted", %{admin_key: key} do
      conn = invalidate(key, %{url: @url})

      assert conn.status in [200, 503]
    end
  end

  describe "the request" do
    test "rejects a missing url", %{admin_key: key} do
      conn = invalidate(key, %{})

      assert conn.status == 400
      assert Poison.decode!(conn.resp_body)["error"] =~ "url"
    end

    test "rejects an empty url", %{admin_key: key} do
      conn = invalidate(key, %{url: ""})

      assert conn.status == 400
    end
  end

  describe "the pre-existing gap this closed" do
    test "an analyze-scoped key cannot export the cache", %{plain_key: key} do
      # Before this, no /v1/cache route checked scope and the auth plug did not
      # either -- any key that could call the API could download every cached
      # report.
      conn =
        conn(:get, "/v1/cache/export")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LowendinsightGet.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "an analyze-scoped key cannot import over the cache", %{plain_key: key} do
      # The sharper half: import rewrites cached reports, so this was a way to
      # change the answers everyone else received.
      conn =
        conn(:post, "/v1/cache/import", Poison.encode!(%{entries: []}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LowendinsightGet.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "an admin key still can", %{admin_key: key} do
      conn =
        conn(:get, "/v1/cache/export")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LowendinsightGet.Endpoint.call(@opts)

      assert conn.status == 200
    end
  end

  describe "routing" do
    test "the route is reachable, not swallowed by the endpoint catch-all", %{admin_key: key} do
      # A route present in the endpoint but missing from @auth_paths returns
      # 404 in production while every test of the handler passes. #69 shipped
      # eight of those at once.
      conn = invalidate(key, %{url: @url})

      refute conn.status == 404
      refute conn.resp_body =~ "UUID not provided or found"
    end
  end
end
