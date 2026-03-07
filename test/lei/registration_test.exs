defmodule Lei.RegistrationTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    # Create admin key for authenticated requests
    {:ok, org} = Lei.ApiKeys.find_or_create_org("Admin Org")
    {:ok, admin_key, _} = Lei.ApiKeys.create_api_key(org, "admin", ["admin"])
    %{admin_key: admin_key, org: org}
  end

  describe "POST /v1/orgs" do
    test "creates a new org", %{admin_key: key} do
      conn =
        conn(:post, "/v1/orgs", Poison.encode!(%{name: "Test Organization"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 201
      body = Poison.decode!(conn.resp_body)
      assert body["name"] == "Test Organization"
      assert body["slug"] == "test-organization"
      assert body["tier"] == "free"
    end

    test "returns existing org if slug matches", %{admin_key: key} do
      conn1 =
        conn(:post, "/v1/orgs", Poison.encode!(%{name: "Dupe Org"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      conn2 =
        conn(:post, "/v1/orgs", Poison.encode!(%{name: "Dupe Org"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      body1 = Poison.decode!(conn1.resp_body)
      body2 = Poison.decode!(conn2.resp_body)
      assert body1["id"] == body2["id"]
    end

    test "returns 400 when name missing", %{admin_key: key} do
      conn =
        conn(:post, "/v1/orgs", Poison.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 400
    end
  end

  describe "POST /v1/orgs/:slug/keys" do
    test "creates an API key for org", %{admin_key: key, org: org} do
      conn =
        conn(:post, "/v1/orgs/#{org.slug}/keys", Poison.encode!(%{name: "ci-key", scopes: ["analyze"]}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 201
      body = Poison.decode!(conn.resp_body)
      assert String.starts_with?(body["key"], "lei_")
      assert body["name"] == "ci-key"
      assert body["scopes"] == ["analyze"]
      assert body["warning"] =~ "not be shown again"
    end

    test "returns 404 for nonexistent org", %{admin_key: key} do
      conn =
        conn(:post, "/v1/orgs/nonexistent-org/keys", Poison.encode!(%{name: "test"}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 404
    end

    test "uses default name when not provided", %{admin_key: key, org: org} do
      conn =
        conn(:post, "/v1/orgs/#{org.slug}/keys", Poison.encode!(%{}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 201
      body = Poison.decode!(conn.resp_body)
      assert body["name"] == "default"
    end
  end

  describe "GET /v1/orgs/:slug/keys" do
    test "lists keys for org", %{admin_key: key, org: org} do
      Lei.ApiKeys.create_api_key(org, "key-1", ["analyze"])
      Lei.ApiKeys.create_api_key(org, "key-2", ["analyze", "admin"])

      conn =
        conn(:get, "/v1/orgs/#{org.slug}/keys")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)
      # admin key + 2 created = at least 3
      assert length(body["keys"]) >= 3
      first = hd(body["keys"])
      assert Map.has_key?(first, "name")
      assert Map.has_key?(first, "key_prefix")
      refute Map.has_key?(first, "key_hash")
    end

    test "returns 404 for nonexistent org", %{admin_key: key} do
      conn =
        conn(:get, "/v1/orgs/nonexistent/keys")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 404
    end
  end

  describe "DELETE /v1/orgs/:slug/keys/:key_id" do
    test "revokes a key", %{admin_key: key, org: org} do
      {:ok, _raw, api_key} = Lei.ApiKeys.create_api_key(org, "to-revoke")

      conn =
        conn(:delete, "/v1/orgs/#{org.slug}/keys/#{api_key.id}")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)
      assert body["status"] == "revoked"
    end

    test "returns 404 for nonexistent key", %{admin_key: key, org: org} do
      conn =
        conn(:delete, "/v1/orgs/#{org.slug}/keys/999999")
        |> put_req_header("authorization", "Bearer #{key}")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 404
    end
  end
end
