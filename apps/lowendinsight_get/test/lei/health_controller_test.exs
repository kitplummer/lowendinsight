defmodule Lei.Web.Controllers.HealthControllerTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  test "GET /v1/health returns 200 with JSON content-type" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "application/json"
  end

  test "GET /v1/health returns status ok" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    body = Poison.decode!(conn.resp_body)
    assert body["status"] == "ok"
  end

  test "GET /v1/health includes app version" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    body = Poison.decode!(conn.resp_body)
    assert is_binary(body["version"])
    assert body["version"] != ""
  end

  test "GET /v1/health includes non-negative uptime_seconds" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    body = Poison.decode!(conn.resp_body)
    assert is_integer(body["uptime_seconds"])
    assert body["uptime_seconds"] >= 0
  end

  test "GET /v1/health is accessible without authentication" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    refute conn.halted
  end
end
