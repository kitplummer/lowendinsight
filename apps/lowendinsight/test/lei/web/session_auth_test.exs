defmodule Lei.Web.SessionAuthTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp build_conn_with_session(session_data) do
    secret = Application.get_env(:lowendinsight, :session_secret_key_base)

    opts =
      Plug.Session.init(
        store: :cookie,
        key: "_lei_session",
        signing_salt: "lei_auth",
        secret_key_base: secret
      )

    Plug.Test.conn(:get, "/dashboard")
    |> Map.put(:secret_key_base, secret)
    |> Plug.Session.call(opts)
    |> Plug.Conn.fetch_session()
    |> then(fn conn ->
      Enum.reduce(session_data, conn, fn {k, v}, acc ->
        Plug.Conn.put_session(acc, k, v)
      end)
    end)
  end

  test "redirects to /login when no session" do
    conn = build_conn_with_session(%{})
    conn = Lei.Web.SessionAuth.call(conn, [])

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
    assert conn.halted
  end

  test "redirects to /login when org_slug is invalid" do
    conn = build_conn_with_session(%{"org_slug" => "nonexistent-org"})
    conn = Lei.Web.SessionAuth.call(conn, [])

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
    assert conn.halted
  end

  test "assigns current_org when session is valid" do
    {:ok, org} = Lei.ApiKeys.find_or_create_org("Session Test Org")

    conn = build_conn_with_session(%{"org_slug" => org.slug})
    conn = Lei.Web.SessionAuth.call(conn, [])

    refute conn.halted
    assert conn.assigns[:current_org].id == org.id
    assert conn.assigns[:current_org].slug == org.slug
  end
end
