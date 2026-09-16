defmodule LeiService.CacheInvalidateTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Lei.ApiKeys

  @opts LeiService.Endpoint.init([])
  @url "https://github.com/kitplummer/canary-test-repo"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})

    {:ok, org} =
      ApiKeys.find_or_create_org("Cache Inv #{System.unique_integer([:positive])}",
        status: "active"
      )

    {:ok, admin_key, _} = ApiKeys.create_api_key(org, "admin", ["admin"])
    {:ok, cache_key, _} = ApiKeys.create_api_key(org, "cache", ["cache"])
    {:ok, plain_key, _} = ApiKeys.create_api_key(org, "plain", ["analyze"])

    %{admin_key: admin_key, cache_key: cache_key, plain_key: plain_key}
  end

  defp invalidate(key, payload) do
    conn = conn(:post, "/v1/cache/invalidate", Poison.encode!(payload))

    conn = put_req_header(conn, "content-type", "application/json")

    conn =
      if key, do: put_req_header(conn, "authorization", "Bearer #{key}"), else: conn

    LeiService.Endpoint.call(conn, @opts)
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

    test "an org admin key is refused: admin of an org is not a platform scope", %{admin_key: key} do
      # Every signup key carries "admin" for its own org. Accepting it here let
      # any stranger force re-analysis of anything (security, 2026-09-14).
      conn = invalidate(key, %{url: @url})

      assert conn.status == 403
    end
  end

  describe "the request" do
    test "rejects a missing url", %{cache_key: key} do
      conn = invalidate(key, %{})

      assert conn.status == 400
      assert Poison.decode!(conn.resp_body)["error"] =~ "url"
    end

    test "rejects an empty url", %{cache_key: key} do
      conn = invalidate(key, %{url: ""})

      assert conn.status == 400
    end
  end

  describe "least privilege" do
    test "a cache-scoped key can invalidate", %{cache_key: key} do
      # The canary needs exactly this and nothing else. An admin key would also
      # let it create orgs and mint further keys -- more authority in a CI
      # secret than the job requires.
      conn = invalidate(key, %{url: @url})

      assert conn.status in [200, 503]
      refute conn.status == 403
    end

    test "a cache-scoped key cannot create orgs", %{cache_key: key} do
      conn =
        conn(:post, "/v1/orgs", Poison.encode!(%{name: "should-not-exist"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LeiService.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "an operator JWT still works on cache routes" do
      # Narrowing must not lock out the operator credential -- which is a JWT,
      # not an org's "admin" key.
      signer = Joken.Signer.create("HS256", Application.get_env(:lei_service, :jwt_secret))
      {:ok, jwt, _} = Joken.generate_and_sign(%{}, operator_claims(), signer)
      conn = invalidate(jwt, %{url: @url})

      assert conn.status in [200, 503]
      refute conn.status == 403
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
        |> LeiService.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "an analyze-scoped key cannot import over the cache", %{plain_key: key} do
      # The sharper half: import rewrites cached reports, so this was a way to
      # change the answers everyone else received.
      conn =
        conn(:post, "/v1/cache/import", Poison.encode!(%{entries: []}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LeiService.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "an org admin key cannot either (security, 2026-09-14)", %{admin_key: key} do
      # Export dumped every cached report, which then embedded the app's
      # secrets. "admin" was accepted, and every signup key has it.
      conn =
        conn(:get, "/v1/cache/export")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LeiService.Endpoint.call(@opts)

      assert conn.status == 403
    end

    test "a cache-scoped key can export", %{cache_key: key} do
      conn =
        conn(:get, "/v1/cache/export")
        |> put_req_header("authorization", "Bearer #{key}")
        |> LeiService.Endpoint.call(@opts)

      assert conn.status == 200
    end
  end

  describe "routing" do
    test "the route is reachable, not swallowed by the endpoint catch-all", %{cache_key: key} do
      # A route present in the endpoint but missing from @auth_paths returns
      # 404 in production while every test of the handler passes. #69 shipped
      # eight of those at once.
      conn = invalidate(key, %{url: @url})

      refute conn.status == 404
      refute conn.resp_body =~ "UUID not provided or found"
    end
  end

  # An operator token needs an expiry now: one without it is refused, and one
  # too far out is too (Lei.OperatorToken).
  defp operator_claims do
    %{"exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}
  end
end
