defmodule Lei.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    Lei.BatchCache.clear()
    :ok
  end

  test "POST /v1/analyze/batch with valid dependencies" do
    body = %{
      "dependencies" => [
        %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}
      ]
    }

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["summary"]["total"] == 1
    assert is_binary(response["analyzed_at"])
  end

  test "POST /v1/analyze/batch with missing dependencies returns 400" do
    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(%{}))
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "missing required field"
  end

  test "POST /v1/analyze/batch with invalid dependency format returns 400" do
    body = %{
      "dependencies" => [
        %{"ecosystem" => "npm"}
      ]
    }

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "ecosystem, package, and version"
  end

  test "POST /v1/analyze/batch with empty dependencies returns 400" do
    body = %{"dependencies" => []}

    conn =
      conn(:post, "/v1/analyze/batch", Poison.encode!(body))
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
  end

  test "GET /v1/health returns ok" do
    conn =
      conn(:get, "/v1/health")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["status"] == "ok"
  end

  test "unknown route returns 404" do
    conn =
      conn(:get, "/nonexistent")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 404
  end
end
