defmodule Lei.Acp.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Acp.Auth

  describe "with no auth configured (dev mode)" do
    setup do
      # Ensure no auth is configured
      old_bearer = Application.get_env(:lowendinsight, :acp_bearer_token)
      old_signing = Application.get_env(:lowendinsight, :acp_signing_secret)
      Application.put_env(:lowendinsight, :acp_bearer_token, nil)
      Application.put_env(:lowendinsight, :acp_signing_secret, nil)

      on_exit(fn ->
        if old_bearer, do: Application.put_env(:lowendinsight, :acp_bearer_token, old_bearer)
        if old_signing, do: Application.put_env(:lowendinsight, :acp_signing_secret, old_signing)
      end)

      :ok
    end

    test "passes through without auth headers" do
      conn =
        conn(:post, "/acp/checkout")
        |> Auth.call(%{})

      refute conn.halted
    end
  end

  describe "with bearer token configured" do
    setup do
      Application.put_env(:lowendinsight, :acp_bearer_token, "test_token_123")
      Application.put_env(:lowendinsight, :acp_signing_secret, nil)

      on_exit(fn ->
        Application.put_env(:lowendinsight, :acp_bearer_token, nil)
      end)

      :ok
    end

    test "accepts valid bearer token" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_req_header("authorization", "Bearer test_token_123")
        |> Auth.call(%{})

      refute conn.halted
    end

    test "rejects invalid bearer token" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_req_header("authorization", "Bearer wrong_token")
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects missing auth header" do
      conn =
        conn(:post, "/acp/checkout")
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end
  end

  describe "with HMAC signing configured" do
    setup do
      Application.put_env(:lowendinsight, :acp_bearer_token, nil)
      Application.put_env(:lowendinsight, :acp_signing_secret, "hmac_secret")

      on_exit(fn ->
        Application.put_env(:lowendinsight, :acp_signing_secret, nil)
      end)

      :ok
    end

    test "accepts valid HMAC signature" do
      body = ~s({"sku":"lei-free"})

      signature =
        :crypto.mac(:hmac, :sha256, "hmac_secret", body) |> Base.encode16(case: :lower)

      conn =
        conn(:post, "/acp/checkout")
        |> put_private(:raw_body, body)
        |> put_req_header("x-acp-signature", signature)
        |> Auth.call(%{})

      refute conn.halted
    end

    test "rejects invalid HMAC signature" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_private(:raw_body, ~s({"sku":"lei-free"}))
        |> put_req_header("x-acp-signature", "invalid_sig")
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects missing signature header" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_private(:raw_body, ~s({"sku":"lei-free"}))
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end
  end
end
