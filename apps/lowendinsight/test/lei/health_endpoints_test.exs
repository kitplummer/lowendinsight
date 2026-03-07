defmodule Lei.HealthEndpointsTest do
  use ExUnit.Case, async: false
  import Plug.Test

  @opts Lei.Web.Router.init([])

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Lei.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Lei.Repo, {:shared, self()})
    :ok
  end

  test "GET /healthz returns 200 with ok status (no auth required)" do
    conn =
      conn(:get, "/healthz")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    body = Poison.decode!(conn.resp_body)
    assert body["status"] == "ok"
  end

  test "GET /readyz returns 200 when database is healthy (no auth required)" do
    conn =
      conn(:get, "/readyz")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    body = Poison.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["checks"]["database"] == "ok"
  end

  test "GET /metrics returns prometheus text format (no auth required)" do
    conn =
      conn(:get, "/metrics")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200

    [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert content_type =~ "text/plain"

    assert conn.resp_body =~ "beam_memory_bytes"
    assert conn.resp_body =~ "beam_process_count"
    assert conn.resp_body =~ "lei_cache_entries_total"
  end

  test "health endpoints do not require authentication" do
    for path <- ["/healthz", "/readyz", "/metrics"] do
      conn =
        conn(:get, path)
        |> Lei.Web.Router.call(@opts)

      assert conn.status in [200, 503], "#{path} returned #{conn.status}"
      refute conn.halted
    end
  end
end
