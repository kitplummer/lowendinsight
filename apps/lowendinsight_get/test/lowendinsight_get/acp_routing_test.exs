defmodule LowendinsightGet.AcpRoutingTest do
  @moduledoc """
  Integration tests for the ACP (Agentic Commerce Protocol) routes as they are
  actually mounted on LowendinsightGet.Endpoint.

  These drive the full endpoint pipeline rather than Lei.Acp.Router directly.
  The existing ACP tests exercise the context module and the auth plug in
  isolation, so a mount that never dispatched -- every /acp request falling
  through to the router's catch-all 404 -- passed all of them.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Acp

  @opts LowendinsightGet.Endpoint.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp post_acp(path, body, headers \\ []) do
    payload = Poison.encode!(body)

    Enum.reduce(headers, conn(:post, path, payload), fn {k, v}, c ->
      put_req_header(c, k, v)
    end)
    |> put_req_header("content-type", "application/json")
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  defp sign(payload, secret) do
    :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
  end

  describe "POST /acp/checkout" do
    test "creates a session" do
      conn = post_acp("/acp/checkout", %{sku: "lei-free"})

      assert conn.status == 201
      body = Poison.decode!(conn.resp_body)
      assert String.starts_with?(body["id"], "acp_cs_")
      assert body["sku"] == "lei-free"
      assert body["status"] == "open"
    end

    test "reports amount for a paid SKU" do
      conn = post_acp("/acp/checkout", %{sku: "lei-pro-monthly"})

      assert conn.status == 201
      assert Poison.decode!(conn.resp_body)["amount_cents"] == 2900
    end

    test "rejects an invalid SKU with 400, not the catch-all 404" do
      conn = post_acp("/acp/checkout", %{sku: "not-a-real-sku"})

      assert conn.status == 400
      assert Poison.decode!(conn.resp_body)["error"] == "invalid SKU"
    end
  end

  describe "POST /acp/checkout/:id" do
    test "updates customer details" do
      {:ok, session} = Acp.create_session("lei-free")

      conn = post_acp("/acp/checkout/#{session.id}", %{customer_name: "Agent Corp"})

      assert conn.status == 200
      assert Poison.decode!(conn.resp_body)["customer_name"] == "Agent Corp"
    end
  end

  describe "POST /acp/checkout/:id/cancel" do
    test "cancels an open session" do
      {:ok, session} = Acp.create_session("lei-free")

      conn = post_acp("/acp/checkout/#{session.id}/cancel", %{})

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)
      assert body["id"] == session.id
      assert body["status"] == "cancelled"
    end
  end

  describe "POST /acp/checkout/:id/complete" do
    # Deliberately does not complete a real session: that path calls out to
    # Stripe. An unknown id is enough to prove the three-segment route matched,
    # because its 404 body differs from the router's catch-all.
    test "routes to the complete handler" do
      conn = post_acp("/acp/checkout/acp_cs_nonexistent/complete", %{})

      assert conn.status == 404
      assert Poison.decode!(conn.resp_body)["error"] == "session not found"
    end
  end

  describe "unmatched ACP paths" do
    test "still fall through to the ACP catch-all" do
      conn = post_acp("/acp/nope", %{})

      assert conn.status == 404
      assert Poison.decode!(conn.resp_body)["error"] == "not found"
    end
  end

  describe "HMAC signature verification" do
    # The endpoint's Plug.Parsers consumes the body before Lei.Acp.Router's own
    # parsers run, so the endpoint must be the one to stash conn.private[:raw_body].
    setup do
      secret = "acp-test-signing-secret"
      Application.put_env(:lowendinsight, :acp_signing_secret, secret)
      on_exit(fn -> Application.put_env(:lowendinsight, :acp_signing_secret, nil) end)
      {:ok, secret: secret}
    end

    test "accepts a request whose signature matches the raw body", %{secret: secret} do
      body = %{sku: "lei-free"}
      signature = sign(Poison.encode!(body), secret)

      conn = post_acp("/acp/checkout", body, [{"x-acp-signature", signature}])

      assert conn.status == 201
    end

    test "rejects a bad signature", %{secret: secret} do
      body = %{sku: "lei-free"}
      signature = sign(Poison.encode!(%{sku: "something-else"}), secret)

      conn = post_acp("/acp/checkout", body, [{"x-acp-signature", signature}])

      assert conn.status == 401
      assert Poison.decode!(conn.resp_body)["error"] == "invalid HMAC signature"
    end

    test "rejects a missing signature" do
      conn = post_acp("/acp/checkout", %{sku: "lei-free"})

      assert conn.status == 401
      assert Poison.decode!(conn.resp_body)["error"] == "missing x-acp-signature header"
    end
  end
end
