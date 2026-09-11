defmodule Lei.Acp.RateLimitTest do
  @moduledoc """
  ACP is unauthenticated by design (ADR-001: agents self-provision without a
  pre-shared secret). Rate limiting is therefore the only thing bounding
  session and org creation from an anonymous caller.

  Includes router-level cases deliberately. Testing the plug alone would not
  notice it being unwired from Lei.Acp.Router -- the same gap guard
  verification caught in org_takeover_test.exs.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @router_opts Lei.Acp.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    Lei.RateLimiter.clear()
    :ok
  end

  defp acp_conn(path, ip) do
    conn(:post, path, ~s({"sku":"lei-free"}))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("fly-client-ip", ip)
  end

  defp limited?(conn), do: conn.halted and conn.status == 429

  # Read the limit rather than hardcoding it. Lei.RateLimiter falls back to the
  # free-tier limit (60) if :rate_limits is unset or the bucket atom does not
  # exist, so a hardcoded 20 silently tests nothing when config is not loaded --
  # which is exactly how this test flaked.
  defp limit_for(bucket) do
    Application.get_env(:lowendinsight, :rate_limits, %{})
    |> Map.get(String.to_atom(bucket))
  end

  defp exhaust(bucket, path, ip) do
    for _ <- 1..limit_for(bucket), do: Lei.Acp.RateLimit.call(acp_conn(path, ip), [])
    :ok
  end

  describe "through the router" do
    test "an anonymous caller is eventually rate limited" do
      ip = "203.0.113.1"

      results =
        for _ <- 1..(limit_for("acp") + 5) do
          acp_conn("/checkout", ip) |> Lei.Acp.Router.call(@router_opts)
        end

      assert Enum.any?(results, &(&1.status == 429)),
             "ACP accepted #{limit_for("acp") + 5} unauthenticated session creations without limiting"
    end

    test "an unlimited caller would otherwise create unbounded sessions" do
      # First request must succeed -- limiting must not break the happy path.
      conn = acp_conn("/checkout", "203.0.113.2") |> Lei.Acp.Router.call(@router_opts)
      assert conn.status == 201
    end
  end

  describe "configuration" do
    # Every other case in this file depends on these being set. Without them
    # Lei.RateLimiter silently uses the free-tier limit and the tests pass
    # while asserting nothing.
    test "acp buckets are configured" do
      limits = Application.get_env(:lowendinsight, :rate_limits)

      assert is_map(limits), ":rate_limits is not configured"
      assert limits[:acp] == 20
      assert limits[:acp_complete] == 5
      assert limits[:acp_complete] < limits[:acp], "completion must be tighter than sessions"
    end
  end

  describe "session endpoints (acp bucket)" do
    test "allows traffic under the limit" do
      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", "1.2.3.4"), []))
    end

    test "rejects once the bucket is exhausted" do
      ip = "1.2.3.5"
      exhaust("acp", "/checkout", ip)

      conn = Lei.Acp.RateLimit.call(acp_conn("/checkout", ip), [])

      assert limited?(conn)
      assert conn.resp_body =~ "rate limited"
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
    end

    test "buckets are per-IP, so one caller cannot exhaust another" do
      exhaust("acp", "/checkout", "1.2.3.6")

      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", "9.9.9.9"), []))
    end
  end

  describe "completion (acp_complete bucket)" do
    # Completion creates an org and an API key, so it is budgeted far tighter.
    test "is limited well before the session bucket would be" do
      ip = "1.2.3.7"
      path = "/checkout/acp_cs_x/complete"

      exhaust("acp_complete", path, ip)

      assert limited?(Lei.Acp.RateLimit.call(acp_conn(path, ip), []))
    end

    test "does not share a bucket with the session endpoints" do
      ip = "1.2.3.8"
      exhaust("acp_complete", "/checkout/acp_cs_x/complete", ip)

      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", ip), []))
    end
  end

  describe "client identification" do
    test "prefers fly-client-ip over a caller-supplied x-forwarded-for" do
      # x-forwarded-for is caller-controlled. Trusting it would let one client
      # spread load across fabricated IPs and defeat the limit entirely.
      ip = "1.2.3.9"

      for i <- 1..limit_for("acp") do
        conn(:post, "/checkout", "{}")
        |> put_req_header("fly-client-ip", ip)
        |> put_req_header("x-forwarded-for", "10.0.0.#{i}")
        |> Lei.Acp.RateLimit.call([])
      end

      conn =
        conn(:post, "/checkout", "{}")
        |> put_req_header("fly-client-ip", ip)
        |> put_req_header("x-forwarded-for", "10.0.0.254")
        |> Lei.Acp.RateLimit.call([])

      assert limited?(conn), "a spoofed x-forwarded-for must not reset the bucket"
    end
  end
end
