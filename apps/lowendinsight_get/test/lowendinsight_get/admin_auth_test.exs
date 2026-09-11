defmodule LowendinsightGet.AdminAuthTest do
  @moduledoc """
  The /admin dashboard shipped and then returned 401 unconditionally in
  production for months, because LEI_ADMIN_TOKEN was never set and an empty
  expected token denies everyone.

  Failing closed is correct. These pin that behaviour down, and cover the two
  weaknesses fixed alongside it: constant-time comparison, and accepting the
  token in a header so it need not travel in a query string.
  """
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts LowendinsightGet.Endpoint.init([])
  @token "test-admin-token-9f3a"

  setup do
    previous = System.get_env("LEI_ADMIN_TOKEN")

    on_exit(fn ->
      if previous do
        System.put_env("LEI_ADMIN_TOKEN", previous)
      else
        System.delete_env("LEI_ADMIN_TOKEN")
      end
    end)

    :ok
  end

  defp get_admin(path, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {k, v}, c -> put_req_header(c, k, v) end)
    |> LowendinsightGet.Endpoint.call(@opts)
  end

  describe "when LEI_ADMIN_TOKEN is unset" do
    setup do
      System.delete_env("LEI_ADMIN_TOKEN")
      :ok
    end

    test "denies even an empty token rather than matching it" do
      # The original bug's shape: "" == "" must not grant access.
      assert get_admin("/admin?token=").status == 401
      assert get_admin("/admin").status == 401
    end

    test "denies an arbitrary token" do
      assert get_admin("/admin?token=anything").status == 401
    end
  end

  describe "when LEI_ADMIN_TOKEN is set" do
    setup do
      System.put_env("LEI_ADMIN_TOKEN", @token)
      :ok
    end

    test "accepts the token as a query parameter" do
      conn = get_admin("/admin?token=#{@token}")

      assert conn.status == 200
      assert conn.resp_body =~ "Cache"
    end

    test "accepts the token as an Authorization header" do
      conn = get_admin("/admin", [{"authorization", "Bearer #{@token}"}])

      assert conn.status == 200
    end

    test "the header takes precedence over the query parameter" do
      conn = get_admin("/admin?token=wrong", [{"authorization", "Bearer #{@token}"}])

      assert conn.status == 200
    end

    test "rejects a wrong token" do
      assert get_admin("/admin?token=wrong").status == 401
    end

    test "rejects a missing token" do
      assert get_admin("/admin").status == 401
    end

    test "rejects a token that is a prefix of the real one" do
      # secure_compare/2 length-checks first; a prefix must not pass.
      assert get_admin("/admin?token=#{String.slice(@token, 0..5)}").status == 401
    end
  end
end
