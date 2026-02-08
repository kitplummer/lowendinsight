# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    Lei.BatchCache.init()
    Lei.BatchCache.clear()
    :ok
  end

  test "POST /v1/analyze/batch returns results for cached deps" do
    Lei.BatchCache.put("npm", "express", "4.18.2", %{"risk" => "low"})

    body =
      Poison.encode!(%{
        "dependencies" => [
          %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}
        ]
      })

    conn =
      conn(:post, "/v1/analyze/batch", body)
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["summary"]["total"] == 1
    assert response["summary"]["cached"] == 1
  end

  test "POST /v1/analyze/batch returns 400 for missing dependencies" do
    body = Poison.encode!(%{"foo" => "bar"})

    conn =
      conn(:post, "/v1/analyze/batch", body)
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "dependencies"
  end

  test "POST /v1/analyze/batch returns 400 for empty dependencies" do
    body = Poison.encode!(%{"dependencies" => []})

    conn =
      conn(:post, "/v1/analyze/batch", body)
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "empty"
  end

  test "POST /v1/analyze/batch returns 400 for invalid dependency format" do
    body =
      Poison.encode!(%{
        "dependencies" => [%{"ecosystem" => "npm"}]
      })

    conn =
      conn(:post, "/v1/analyze/batch", body)
      |> put_req_header("content-type", "application/json")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 400
    response = Poison.decode!(conn.resp_body)
    assert response["error"] =~ "ecosystem"
  end

  test "GET /v1/jobs/:id returns 404 for unknown job" do
    conn =
      conn(:get, "/v1/jobs/job-nonexistent")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 404
  end

  test "GET /v1/jobs/:id returns job details" do
    job_id = Lei.Registry.create_job(%{"ecosystem" => "npm", "package" => "test", "version" => "1.0.0"})

    conn =
      conn(:get, "/v1/jobs/#{job_id}")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["job_id"] == job_id
    assert response["status"] == "pending"
  end

  test "GET /health returns ok" do
    conn =
      conn(:get, "/health")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 200
    response = Poison.decode!(conn.resp_body)
    assert response["status"] == "ok"
  end

  test "unknown routes return 404" do
    conn =
      conn(:get, "/unknown")
      |> Lei.Web.Router.call(@opts)

    assert conn.status == 404
  end
end
