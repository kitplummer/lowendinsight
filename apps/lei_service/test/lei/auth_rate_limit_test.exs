defmodule Lei.AuthRateLimitTest do
  @moduledoc """
  Signup, login and recovery are rate limited per IP.

  All three are unauthenticated by necessity. Login takes an API key and
  recovery takes a slug and a recovery code that returns a **new admin API
  key**, and neither had any limit: an attacker could grind through codes as
  fast as the service would answer (security review, 2026-09-14).
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    # The attempts below reach the handlers, which query for the org or key.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Lei.RateLimiter.clear()
    :ok
  end

  defp post_form(path, params, ip) do
    conn(:post, path, URI.encode_query(params))
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> put_req_header("fly-client-ip", ip)
    |> Lei.Web.Router.call(@opts)
  end

  defp limit_for(bucket) do
    Application.get_env(:lei_service, :rate_limits)[bucket] ||
      flunk("no rate limit configured for #{bucket}")
  end

  test "recovery attempts are capped, and the cap is tight" do
    limit = limit_for(:recover)
    assert limit <= 10, "a recovery code that mints an admin key must not allow many guesses"

    for _ <- 1..limit do
      conn = post_form("/recover", %{"slug" => "nope", "recovery_code" => "wrong"}, "203.0.113.9")
      refute conn.status == 429
    end

    conn = post_form("/recover", %{"slug" => "nope", "recovery_code" => "wrong"}, "203.0.113.9")
    assert conn.status == 429
    assert get_resp_header(conn, "retry-after") != []
  end

  test "login attempts are capped" do
    limit = limit_for(:login)

    for _ <- 1..limit do
      refute post_form("/login", %{"api_key" => "lei_bogus"}, "203.0.113.10").status == 429
    end

    assert post_form("/login", %{"api_key" => "lei_bogus"}, "203.0.113.10").status == 429
  end

  test "signups are capped" do
    limit = limit_for(:signup)

    for i <- 1..limit do
      refute post_form("/signup", %{"name" => "org-#{i}", "tier" => "free"}, "203.0.113.11").status ==
               429
    end

    assert post_form("/signup", %{"name" => "org-x", "tier" => "free"}, "203.0.113.11").status ==
             429
  end

  test "one address's attempts do not limit another's" do
    for _ <- 1..limit_for(:login) do
      post_form("/login", %{"api_key" => "lei_bogus"}, "203.0.113.12")
    end

    assert post_form("/login", %{"api_key" => "lei_bogus"}, "203.0.113.12").status == 429
    refute post_form("/login", %{"api_key" => "lei_bogus"}, "198.51.100.7").status == 429
  end

  test "the limit counts attempts, not failures, so a correct guess still costs" do
    # Otherwise an attacker pays nothing for the attempt that succeeds, and a
    # credential-stuffing run is limited only by its failures.
    limit = limit_for(:login)
    for _ <- 1..limit, do: post_form("/login", %{"api_key" => ""}, "203.0.113.13")
    assert post_form("/login", %{"api_key" => ""}, "203.0.113.13").status == 429
  end
end
