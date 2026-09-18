defmodule Lei.Acp.AuthTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Lei.Acp.Auth

  describe "with no auth configured (dev mode)" do
    setup do
      # Ensure no auth is configured
      old_bearer = Application.get_env(:lei_service, :acp_bearer_token)
      old_signing = Application.get_env(:lei_service, :acp_signing_secret)
      Application.put_env(:lei_service, :acp_bearer_token, nil)
      Application.put_env(:lei_service, :acp_signing_secret, nil)

      on_exit(fn ->
        if old_bearer, do: Application.put_env(:lei_service, :acp_bearer_token, old_bearer)
        if old_signing, do: Application.put_env(:lei_service, :acp_signing_secret, old_signing)
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
      Application.put_env(:lei_service, :acp_bearer_token, "test_token_123")
      Application.put_env(:lei_service, :acp_signing_secret, nil)

      on_exit(fn ->
        Application.put_env(:lei_service, :acp_bearer_token, nil)
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
      Application.put_env(:lei_service, :acp_bearer_token, nil)
      Application.put_env(:lei_service, :acp_signing_secret, "hmac_secret")

      on_exit(fn ->
        Application.put_env(:lei_service, :acp_signing_secret, nil)
      end)

      :ok
    end

    test "accepts valid HMAC signature" do
      body = ~s({"sku":"lei-credits-29000"})

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
        |> put_private(:raw_body, ~s({"sku":"lei-credits-29000"}))
        |> put_req_header("x-acp-signature", "invalid_sig")
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end

    test "rejects missing signature header" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_private(:raw_body, ~s({"sku":"lei-credits-29000"}))
        |> Auth.call(%{})

      assert conn.status == 401
      assert conn.halted
    end
  end

  # -- unconfigured is not a pass (#139)
  #
  # Both checks used to return {:ok, conn} -- authenticated -- when their
  # secret was absent, commented "dev mode". Neither secret was ever set in
  # production, so POST /acp/checkout and /complete were open to anyone for as
  # long as they have existed. The only thing bounding it was that the single
  # SKU charges $29, which is a pricing accident rather than a control.
  #
  # The opt-in is explicit and lives in config/dev.exs and config/test.exs,
  # rather than being inferred from LEI_DEPLOY_ENV. A deploy that loses that
  # variable would otherwise re-open the endpoint, which is the same
  # dependency that already downgrades Lei.Stripe.ObjectCheck to "ok".

  describe "unconfigured, without the development opt-in" do
    setup do
      saved = {
        Application.get_env(:lei_service, :acp_bearer_token),
        Application.get_env(:lei_service, :acp_signing_secret),
        Application.get_env(:lei_service, :acp_allow_unauthenticated),
        Application.get_env(:lei_service, :deploy_env)
      }

      Application.put_env(:lei_service, :acp_bearer_token, nil)
      Application.put_env(:lei_service, :acp_signing_secret, nil)
      Application.delete_env(:lei_service, :acp_allow_unauthenticated)

      on_exit(fn ->
        {bearer, signing, allow, deploy} = saved
        Application.put_env(:lei_service, :acp_bearer_token, bearer)
        Application.put_env(:lei_service, :acp_signing_secret, signing)
        if allow, do: Application.put_env(:lei_service, :acp_allow_unauthenticated, allow)
        if deploy, do: Application.put_env(:lei_service, :deploy_env, deploy)
      end)

      :ok
    end

    test "refuses the request rather than serving it unauthenticated" do
      conn = conn(:post, "/acp/checkout") |> Auth.call(%{})

      assert conn.halted
      assert conn.status == 503
    end

    test "a caller presenting a bearer token is refused too" do
      conn =
        conn(:post, "/acp/checkout")
        |> put_req_header("authorization", "Bearer anything")
        |> Auth.call(%{})

      assert conn.halted
      assert conn.status == 503
    end

    test "the refusal does not disclose which secret is missing" do
      conn = conn(:post, "/acp/checkout") |> Auth.call(%{})

      # Same opaque body the kill switch returns, so an anonymous caller cannot
      # read our configuration state off the response.
      assert Poison.decode!(conn.resp_body) == %{"error" => "checkout unavailable"}
      refute conn.resp_body =~ "bearer"
      refute conn.resp_body =~ "signing"
      refute conn.resp_body =~ "unconfigured"
    end

    test "refusing does not depend on LEI_DEPLOY_ENV being set" do
      Application.delete_env(:lei_service, :deploy_env)

      conn = conn(:post, "/acp/checkout") |> Auth.call(%{})

      assert conn.halted
      assert conn.status == 503
    end

    test "a signing secret alone still refuses, because the bearer check cannot run" do
      Application.put_env(:lei_service, :acp_signing_secret, "hmac_secret")

      body = ~s({"sku":"lei-credits-29000"})
      signature = :crypto.mac(:hmac, :sha256, "hmac_secret", body) |> Base.encode16(case: :lower)

      conn =
        conn(:post, "/acp/checkout")
        |> put_private(:raw_body, body)
        |> put_req_header("x-acp-signature", signature)
        |> Auth.call(%{})

      assert conn.halted
      assert conn.status == 503
    end

    test "a bearer token alone still refuses, because HMAC cannot be verified" do
      Application.put_env(:lei_service, :acp_bearer_token, "test_token_123")

      conn =
        conn(:post, "/acp/checkout")
        |> put_req_header("authorization", "Bearer test_token_123")
        |> Auth.call(%{})

      assert conn.halted
      assert conn.status == 503
    end
  end

  describe "with the development opt-in" do
    setup do
      Application.put_env(:lei_service, :acp_bearer_token, nil)
      Application.put_env(:lei_service, :acp_signing_secret, nil)
      Application.put_env(:lei_service, :acp_allow_unauthenticated, true)
      :ok
    end

    test "passes through, so local development is unchanged" do
      conn = conn(:post, "/acp/checkout") |> Auth.call(%{})
      refute conn.halted
    end
  end
end
