defmodule Lei.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Auth

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()

    {:ok, org} = Lei.ApiKeys.find_or_create_org("Auth Test Org", status: "active")

    {:ok, raw_key, _api_key} =
      Lei.ApiKeys.create_api_key(org, "auth-test-key", ["analyze", "admin"])

    %{raw_key: raw_key}
  end

  # Auth tests use /v1/orgs (requires auth) since /v1/health is now public
  test "accepts valid API key", %{raw_key: raw_key} do
    conn =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert conn.status != 401
    assert conn.assigns[:current_api_key] != nil
    assert conn.assigns[:auth_method] == :api_key
  end

  test "rejects invalid API key" do
    conn =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer lei_invalid_key_here_padding00")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "JWT still works" do
    secret = Application.get_env(:lei_service, :jwt_secret, "lei_dev_secret")
    signer = Joken.Signer.create("HS256", secret)
    {:ok, jwt, _claims} = Joken.generate_and_sign(%{}, operator_claims(), signer)

    conn =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{jwt}")
      |> Auth.call(%{})

    assert conn.status != 401
    refute conn.halted
  end

  test "returns 401 with no auth header on a route that is not paid" do
    conn =
      conn(:get, "/v1/usage")
      |> Auth.call(%{})

    assert conn.status == 401
    assert conn.halted
  end

  test "lets a paid route through unauthenticated, to be asked to pay" do
    # An agent that has never been here has nothing to authenticate with.
    # Lei.Payments.Gate decides, and refuses by default (#147).
    conn =
      conn(:post, "/v1/analyze")
      |> Auth.call(%{})

    refute conn.halted
    assert conn.assigns[:auth_method] == :anonymous
  end

  test "accepts the Payment scheme only on a paid route" do
    paid =
      conn(:post, "/v1/analyze/batch")
      |> put_req_header("authorization", "Payment abc")
      |> Auth.call(%{})

    assert paid.assigns[:auth_method] == :payment
    refute paid.halted

    other =
      conn(:get, "/v1/usage") |> put_req_header("authorization", "Payment abc") |> Auth.call(%{})

    assert other.status == 401
  end

  test "skips auth for non-v1 paths" do
    conn =
      conn(:get, "/")
      |> Auth.call(%{})

    refute conn.halted
  end

  test "skips auth for /v1/health (public path)" do
    conn =
      conn(:get, "/v1/health")
      |> Auth.call(%{})

    refute conn.halted
    assert conn.status != 401
  end

  test "sets x-ratelimit-remaining header for API key auth", %{raw_key: raw_key} do
    conn =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert get_resp_header(conn, "x-ratelimit-remaining") != []
  end

  test "rate limits API key after exceeding limit" do
    {:ok, org} = Lei.ApiKeys.find_or_create_org("Rate Limit Org", status: "active")
    {:ok, raw_key, _} = Lei.ApiKeys.create_api_key(org, "rate-test", ["analyze", "admin"])

    # Restore rather than delete, and do it on exit rather than at the end of
    # the body. Deleting left :rate_limits unset for whatever ran next, which
    # made Lei.Acp.RateLimitTest fail or pass on the ExUnit seed; cleaning up
    # only on the happy path meant one failed assertion here contaminated the
    # rest of the run. Same defect as rate_limiter_test.exs (#99), second file.
    original = Application.get_env(:lei_service, :rate_limits)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:lei_service, :rate_limits)
        value -> Application.put_env(:lei_service, :rate_limits, value)
      end
    end)

    Application.put_env(:lei_service, :rate_limits, %{free: 2, pro: 600})

    conn1 =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    refute conn1.halted

    conn2 =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    refute conn2.halted

    conn3 =
      conn(:post, "/v1/analyze")
      |> put_req_header("authorization", "Bearer #{raw_key}")
      |> Auth.call(%{})

    assert conn3.status == 429
    assert conn3.halted
    body = Poison.decode!(conn3.resp_body)
    assert body["error"] == "rate limit exceeded"
  end

  # An operator token needs an expiry now: one without it is refused, and one
  # too far out is too (Lei.OperatorToken).
  defp operator_claims do
    %{"exp" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_unix()}
  end
end
