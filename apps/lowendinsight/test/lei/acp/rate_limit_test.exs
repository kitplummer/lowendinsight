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

  describe "through the router" do
    test "an anonymous caller is eventually rate limited" do
      ip = "203.0.113.1"

      results =
        for _ <- 1..25 do
          acp_conn("/checkout", ip) |> Lei.Acp.Router.call(@router_opts)
        end

      assert Enum.any?(results, &(&1.status == 429)),
             "ACP accepted 25 unauthenticated session creations without limiting"
    end

    test "an unlimited caller would otherwise create unbounded sessions" do
      # First request must succeed -- limiting must not break the happy path.
      conn = acp_conn("/checkout", "203.0.113.2") |> Lei.Acp.Router.call(@router_opts)
      assert conn.status == 201
    end
  end

  describe "session endpoints (acp bucket, 20/min)" do
    test "allows traffic under the limit" do
      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", "1.2.3.4"), []))
    end

    test "rejects once the bucket is exhausted" do
      ip = "1.2.3.5"
      for _ <- 1..20, do: Lei.Acp.RateLimit.call(acp_conn("/checkout", ip), [])

      conn = Lei.Acp.RateLimit.call(acp_conn("/checkout", ip), [])

      assert limited?(conn)
      assert conn.resp_body =~ "rate limited"
      assert [retry] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
    end

    test "buckets are per-IP, so one caller cannot exhaust another" do
      for _ <- 1..20, do: Lei.Acp.RateLimit.call(acp_conn("/checkout", "1.2.3.6"), [])

      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", "9.9.9.9"), []))
    end
  end

  describe "completion (acp_complete bucket, 5/min)" do
    # Completion creates an org and an API key, so it is budgeted far tighter.
    test "is limited well before the session bucket would be" do
      ip = "1.2.3.7"
      path = "/checkout/acp_cs_x/complete"

      for _ <- 1..5, do: Lei.Acp.RateLimit.call(acp_conn(path, ip), [])

      assert limited?(Lei.Acp.RateLimit.call(acp_conn(path, ip), []))
    end

    test "does not share a bucket with the session endpoints" do
      ip = "1.2.3.8"
      for _ <- 1..5, do: Lei.Acp.RateLimit.call(acp_conn("/checkout/acp_cs_x/complete", ip), [])

      refute limited?(Lei.Acp.RateLimit.call(acp_conn("/checkout", ip), []))
    end
  end

  describe "client identification" do
    test "prefers fly-client-ip over a caller-supplied x-forwarded-for" do
      # x-forwarded-for is caller-controlled. Trusting it would let one client
      # spread load across fabricated IPs and defeat the limit entirely.
      ip = "1.2.3.9"

      for i <- 1..20 do
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
