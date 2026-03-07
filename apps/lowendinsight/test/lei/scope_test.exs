defmodule Lei.ScopeTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Auth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    {:ok, org} = Lei.ApiKeys.find_or_create_org("Scope Test Org")
    {:ok, analyze_key, _} = Lei.ApiKeys.create_api_key(org, "analyze-only", ["analyze"])
    {:ok, admin_key, _} = Lei.ApiKeys.create_api_key(org, "admin-key", ["admin"])
    {:ok, no_scope_key, _} = Lei.ApiKeys.create_api_key(org, "no-scope-key", [])

    %{analyze_key: analyze_key, admin_key: admin_key, no_scope_key: no_scope_key}
  end

  test "API key with 'analyze' scope can access /v1/analyze/*", %{analyze_key: key} do
    conn =
      conn(:post, "/v1/analyze/batch")
      |> put_req_header("authorization", "Bearer #{key}")
      |> Auth.call(%{})

    refute conn.status == 403
  end

  test "API key without 'analyze' scope cannot access /v1/analyze/*", %{no_scope_key: key} do
    conn =
      conn(:post, "/v1/analyze/batch")
      |> put_req_header("authorization", "Bearer #{key}")
      |> Auth.call(%{})

    assert conn.status == 403
    body = Poison.decode!(conn.resp_body)
    assert body["error"] == "insufficient scope"
    assert body["required"] == "analyze"
  end

  test "API key with 'admin' scope can access any endpoint", %{admin_key: key} do
    conn =
      conn(:post, "/v1/analyze/batch")
      |> put_req_header("authorization", "Bearer #{key}")
      |> Auth.call(%{})

    refute conn.status == 403
  end

  test "health endpoint requires no scope", %{no_scope_key: key} do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{key}")
      |> Auth.call(%{})

    refute conn.status == 403
  end

  test "JWT auth bypasses scope check" do
    secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _} = Joken.generate_and_sign(%{}, %{}, signer)

    conn =
      conn(:post, "/v1/analyze/batch")
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call(%{})

    refute conn.status == 403
    refute conn.halted
  end
end
