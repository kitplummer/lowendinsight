defmodule Lei.Web.UiTest do
  use ExUnit.Case, async: false

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  defp call(conn) do
    Lei.Web.Router.call(conn, @opts)
  end

  test "GET /signup renders signup form" do
    conn = Plug.Test.conn(:get, "/signup") |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "Create an Organization"
    assert conn.resp_body =~ "<form"
  end

  test "POST /signup creates org and shows API key" do
    conn =
      Plug.Test.conn(:post, "/signup", "name=TestUIOrg")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "lei_"
    assert conn.resp_body =~ "Save your API key"
    assert conn.resp_body =~ "TestUIOrg"
  end

  test "POST /signup with empty name shows error" do
    conn =
      Plug.Test.conn(:post, "/signup", "name=")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "Organization name is required"
  end

  test "GET /login renders login form" do
    conn = Plug.Test.conn(:get, "/login") |> call()
    assert conn.status == 200
    assert conn.resp_body =~ "API Key"
    assert conn.resp_body =~ "<form"
  end

  test "POST /login with valid admin key redirects to /dashboard" do
    {:ok, org} = Lei.ApiKeys.find_or_create_org("Login Test Org")
    {:ok, raw_key, _api_key} = Lei.ApiKeys.create_api_key(org, "admin", ["admin", "analyze"])

    conn =
      Plug.Test.conn(:post, "/login", "api_key=#{raw_key}")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/dashboard"]
  end

  test "POST /login with invalid key shows error" do
    conn =
      Plug.Test.conn(:post, "/login", "api_key=lei_invalid_key_here")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "Invalid API key"
  end

  test "POST /login with non-admin key shows scope error" do
    {:ok, org} = Lei.ApiKeys.find_or_create_org("NonAdmin Test Org")
    {:ok, raw_key, _api_key} = Lei.ApiKeys.create_api_key(org, "analyze-only", ["analyze"])

    conn =
      Plug.Test.conn(:post, "/login", "api_key=#{raw_key}")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> call()

    assert conn.status == 200
    assert conn.resp_body =~ "admin scope"
  end

  test "GET /dashboard without session redirects to /login" do
    conn = Plug.Test.conn(:get, "/dashboard") |> call()
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
  end

  test "GET /logout redirects to /login" do
    conn = Plug.Test.conn(:get, "/logout") |> call()
    assert conn.status == 302
    assert Plug.Conn.get_resp_header(conn, "location") == ["/login"]
  end
end
