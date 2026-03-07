defmodule Lei.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Auth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    {:ok, org} = Lei.ApiKeys.find_or_create_org("Auth Test Org")
    {:ok, raw_key, _api_key} = Lei.ApiKeys.create_api_key(org, "auth-test-key", ["analyze", "admin"])
    %{raw_key: raw_key}
  end

  test "accepts valid API key", %{raw_key: raw_key} do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert conn.status != 401
    assert conn.assigns[:current_api_key] != nil
    assert conn.assigns[:auth_method] == :api_key
  end

  test "rejects invalid API key" do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer lei_invalid_key_here_padding00")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "JWT still works" do
    secret = Application.get_env(:lowendinsight, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _claims} = Joken.generate_and_sign(%{}, %{}, signer)

    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call(%{})

    assert conn.status != 401
    refute conn.halted
  end

  test "returns 401 with no auth header" do
    conn =
      conn(:get, "/v1/health")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "skips auth for non-v1 paths" do
    conn =
      conn(:get, "/")
      |> Auth.call(%{})

    refute conn.halted
  end

  test "sets x-ratelimit-remaining header for API key auth", %{raw_key: raw_key} do
    conn =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert get_resp_header(conn, "x-ratelimit-remaining") != []
  end

  test "rate limits API key after exceeding limit" do
    {:ok, org} = Lei.ApiKeys.find_or_create_org("Rate Limit Org")
    {:ok, raw_key, _} = Lei.ApiKeys.create_api_key(org, "rate-test", ["analyze", "admin"])

    Application.put_env(:lowendinsight, :rate_limits, %{free: 2, pro: 600})

    conn1 =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    refute conn1.halted

    conn2 =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    refute conn2.halted

    conn3 =
      conn(:get, "/v1/health")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert conn3.status == 429
    assert conn3.halted
    body = Poison.decode!(conn3.resp_body)
    assert body["error"] == "rate limit exceeded"

    Application.delete_env(:lowendinsight, :rate_limits)
  end
end
