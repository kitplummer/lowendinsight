defmodule Lei.Web.RouterTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  @opts Lei.Web.Router.init([])

  setup do
    :ets.delete_all_objects(:lei_analysis_cache)
    :ok
  end

  describe "POST /v1/analyze/batch" do
    test "returns 200 with cached results" do
      Lei.Cache.put("npm", "express", "4.18.2", %{
        "ecosystem" => "npm",
        "package" => "express",
        "version" => "4.18.2",
        "risk" => "low",
        "report" => %{}
      })

      conn =
        conn(:post, "/v1/analyze/batch", %{
          "dependencies" => [
            %{"ecosystem" => "npm", "package" => "express", "version" => "4.18.2"}
          ]
        })
        |> put_req_header("content-type", "application/json")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["summary"]["total"] == 1
      assert body["summary"]["cached"] == 1
      assert length(body["results"]) == 1
    end

    test "returns 400 for empty dependencies list" do
      conn =
        conn(:post, "/v1/analyze/batch", %{"dependencies" => []})
        |> put_req_header("content-type", "application/json")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "empty"
    end

    test "returns 400 for missing dependencies key" do
      conn =
        conn(:post, "/v1/analyze/batch", %{"foo" => "bar"})
        |> put_req_header("content-type", "application/json")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] =~ "dependencies"
    end

    test "enqueues jobs for uncached dependencies" do
      conn =
        conn(:post, "/v1/analyze/batch", %{
          "dependencies" => [
            %{"ecosystem" => "hex", "package" => "some-rare-pkg", "version" => "0.1.0"}
          ]
        })
        |> put_req_header("content-type", "application/json")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["summary"]["pending"] == 1
      assert length(body["pending_jobs"]) == 1
    end
  end

  describe "GET /v1/health" do
    test "returns 200 ok" do
      conn =
        conn(:get, "/v1/health")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn =
        conn(:get, "/v1/nonexistent")
        |> Lei.Web.Router.call(@opts)

      assert conn.status == 404
    end
  end
end
