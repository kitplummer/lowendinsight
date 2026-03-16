# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.EndpointTest do
  use ExUnit.Case, async: true
  use Plug.Test

  @opts LowendinsightGet.Endpoint.init([])
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJKb2tlbiIsImV4cCI6MTY3MDQzNTQ1MSwiaWF0IjoxNjcwNDI4MjUxLCJpc3MiOiJKb2tlbiIsImp0aSI6IjJzbjhyOThiczNiZzNwZWwwZzAwMDA3MiIsIm5iZiI6MTY3MDQyODI1MX0.kQgqr-7lmQtlVeq96hmIIYHEniJq638NQ10VW26kT9k"
  @headers [{"authorization", "Bearer #{@token}"}]

  setup_all do
    Redix.command(:redix, ["FLUSHDB"])

    on_exit(fn ->
      Task.Supervisor.children(LowendinsightGet.AnalysisSupervisor)
      |> Enum.map(fn child ->
        Task.Supervisor.terminate_child(LowendinsightGet.AnalysisSupervisor, child)
      end)
    end)
  end

  test "it returns HTML" do
    # Create a test connection
    conn = conn(:get, "/")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "<html>")
  end

  test "it returns error when error" do
    conn = conn(:get, "/blah")
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 404
  end

  test "it returns 401 with no token" do
    Redix.command(:redix, [
      "DEL",
      LowendinsightGet.Datastore.cache_key("https://github.com/gbtestee/gbtestee")
    ])

    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{urls: ["https://github.com/gbtestee/gbtestee"]})

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 401
    json = Poison.decode!(conn.resp_body)
    assert "Please make sure you have authentication header" == json["message"]
  end

  test "it returns 200 with a valid payload" do
    Redix.command(:redix, [
      "DEL",
      LowendinsightGet.Datastore.cache_key("https://github.com/gbtestee/gbtestee")
    ])

    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{urls: ["https://github.com/gbtestee/gbtestee"]})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 200
    :timer.sleep(2000)
    json = Poison.decode!(conn.resp_body)
    conn = conn(:get, "/v1/analyze/#{json["uuid"]}")
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert "complete" == json["state"]
  end

  test "it returns 200 with a valid payload when cached" do
    Redix.command(:redix, [
      "DEL",
      LowendinsightGet.Datastore.cache_key("https://github.com/kitplummer/git-author")
    ])

    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{urls: ["https://github.com/kitplummer/git-author"]})

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 200
    :timer.sleep(2000)
    json = Poison.decode!(conn.resp_body)
    conn = conn(:get, "/v1/analyze/#{json["uuid"]}")
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert "complete" == json["state"]

    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{urls: ["https://github.com/kitplummer/git-author"]})

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 200
    :timer.sleep(1000)
    json = Poison.decode!(conn.resp_body)
    conn = conn(:get, "/v1/analyze/#{json["uuid"]}")
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert "complete" == json["state"]
  end

  test "it returns 422 with an empty payload" do
    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{})

    # Invoke the plug
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 422
  end

  test "it returns 422 with an invalid json payload" do
    # Create a test connection
    conn = conn(:post, "/v1/analyze", %{urls: ["htps://github.com/kitplummer/xmpp4rails"]})

    # Invoke the plug
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.resp_body == "{\"error\":\"invalid URLs list\"}"
    assert conn.status == 422
  end

  test "it returns 404 when no route matches" do
    # Create a test connection
    conn = conn(:get, "/fail")

    # Invoke the plug
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response
    assert conn.status == 404
  end

  test "it returns 200 for the /gh_trending endpoint" do
    # Create a test connection
    conn = conn(:get, "/gh_trending")
    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "<html>")
  end

  test "it returns 200 for the /gh_trending/language endpoint" do
    # Create a test connection
    conn = conn(:get, "/gh_trending/elixir")
    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "<html>")
  end

  test "it returns 200 for the /doc endpoint" do
    # Create a test connection
    conn = conn(:get, "/doc")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "swagger-ui")
  end

  test "it returns 200 when report is valid for the /url= endpoint" do
    # Create a test connection
    conn = conn(:get, "/url=https%3A%2F%2Fgithub.com%2Fkitplummer%2Fgoa?")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
    assert String.contains?(conn.resp_body, "<html>")
  end

  test "it returns 401 when report is invalid for the /url= endpoint" do
    # Create a test connection
    conn = conn(:get, "/url=https%3A%2F%2Fwww.youtube.com")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 401
  end

  test "it returns 200 when url is valid for /validate-url endpoint" do
    # Create a test connection
    conn = conn(:get, "/validate-url/url=https%3A%2F%2Fgithub.com%2Felixir-lang%2Fex_doc?")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
  end

  test "it returns 200 for the /v1/gh_trending/process endpoint" do
    # Create a test connection
    conn = conn(:post, "/v1/gh_trending/process")

    # Invoke the plug
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 200
  end

  test "it returns 201 when url is invalid for /validate-url endpoint" do
    # Create a test connection
    conn = conn(:get, "/validate-url/url=www.url.com")

    # Invoke the plug
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Assert the response and status
    assert conn.state == :sent
    assert conn.status == 201
  end

  ## cache_mode tests

  test "POST with cache_mode async returns immediately with uuid and incomplete state" do
    # Use unique URL that won't be cached - async mode should queue and return immediately
    unique_url = "https://github.com/test-org-#{:rand.uniform(100_000)}/test-repo-async"
    Redix.command(:redix, ["DEL", unique_url])
    Redix.command(:redix, ["DEL", LowendinsightGet.Datastore.cache_key(unique_url)])

    conn =
      conn(:post, "/v1/analyze", %{
        "urls" => [unique_url],
        "cache_mode" => "async"
      })

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert json["uuid"] != nil
    # Async with uncached URL returns incomplete since job is queued
    assert json["state"] == "incomplete"
  end

  test "POST with cache_mode blocking and short timeout returns incomplete or completes quickly" do
    # Use unique URL that won't be cached - blocking mode with 1ms timeout
    # Note: With such a short timeout, behavior can vary:
    # - 202 with timeout error if job didn't complete
    # - 200 with result if analysis completed/failed quickly
    unique_url = "https://github.com/test-org-#{:rand.uniform(100_000)}/test-repo-blocking"
    Redix.command(:redix, ["DEL", unique_url])
    Redix.command(:redix, ["DEL", LowendinsightGet.Datastore.cache_key(unique_url)])

    conn =
      conn(:post, "/v1/analyze", %{
        "urls" => [unique_url],
        "cache_mode" => "blocking",
        "cache_timeout" => 1
      })

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    # Accept either 200 (completed) or 202 (timeout) since 1ms is extreme
    assert conn.status in [200, 202]
    json = Poison.decode!(conn.resp_body)
    assert json["uuid"] != nil
  end

  test "POST with cache_mode stale returns stale data when cached" do
    url = "https://github.com/kitplummer/goa"
    cache_key = LowendinsightGet.Datastore.cache_key(url)
    # Seed the cache with a fake report using the new cache key format
    fake_report = %{
      "header" => %{"end_time" => DateTime.to_iso8601(DateTime.utc_now())},
      "data" => %{"repo" => url, "results" => %{}}
    }

    Redix.command(:redix, ["SET", cache_key, Poison.encode!(fake_report)])

    conn =
      conn(:post, "/v1/analyze", %{
        "urls" => [url],
        "cache_mode" => "stale"
      })

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert json["stale"] == true
    assert json["state"] == "complete"
    assert json["refresh_job_id"] != nil
  end

  test "POST with invalid cache_mode returns 422" do
    conn =
      conn(:post, "/v1/analyze", %{
        "urls" => ["https://github.com/gbtestee/gbtestee"],
        "cache_mode" => "invalid_mode"
      })

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 422
    json = Poison.decode!(conn.resp_body)
    assert String.contains?(json["error"], "invalid cache_mode")
  end

  test "GET /v1/job/:id returns same as /v1/analyze/:uuid" do
    Redix.command(:redix, ["DELETE", "https://github.com/gbtestee/gbtestee"])
    # First create a job via POST
    conn =
      conn(:post, "/v1/analyze", %{
        "urls" => ["https://github.com/gbtestee/gbtestee"],
        "cache_mode" => "async"
      })

    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    json = Poison.decode!(conn.resp_body)
    uuid = json["uuid"]

    :timer.sleep(2000)

    # Fetch via /v1/analyze/:uuid
    conn_analyze = conn(:get, "/v1/analyze/#{uuid}")
    conn_analyze = Plug.Conn.merge_req_headers(conn_analyze, @headers)
    conn_analyze = LowendinsightGet.Endpoint.call(conn_analyze, @opts)

    # Fetch via /v1/job/:id
    conn_job = conn(:get, "/v1/job/#{uuid}")
    conn_job = Plug.Conn.merge_req_headers(conn_job, @headers)
    conn_job = LowendinsightGet.Endpoint.call(conn_job, @opts)

    assert conn_analyze.status == conn_job.status

    assert Poison.decode!(conn_analyze.resp_body)["state"] ==
             Poison.decode!(conn_job.resp_body)["state"]
  end

  ## SBOM endpoint tests

  test "POST /v1/analyze/sbom with CycloneDX returns 200" do
    sbom = %{
      "bomFormat" => "CycloneDX",
      "specVersion" => "1.4",
      "components" => [
        %{
          "name" => "goa",
          "version" => "1.0.0",
          "purl" => "pkg:github/kitplummer/goa@v1.0.0"
        }
      ]
    }

    conn = conn(:post, "/v1/analyze/sbom", %{"sbom" => sbom, "cache_mode" => "async"})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert json["uuid"] != nil
    assert json["sbom_analysis"] == true
    assert json["sbom_urls_found"] == 1
  end

  test "POST /v1/analyze/sbom with SPDX returns 200" do
    sbom = %{
      "spdxVersion" => "SPDX-2.3",
      "packages" => [
        %{
          "name" => "goa",
          "downloadLocation" => "https://github.com/kitplummer/goa"
        }
      ]
    }

    conn = conn(:post, "/v1/analyze/sbom", %{"sbom" => sbom, "cache_mode" => "async"})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 200
    json = Poison.decode!(conn.resp_body)
    assert json["uuid"] != nil
    assert json["sbom_analysis"] == true
  end

  test "POST /v1/analyze/sbom with no git URLs returns 422" do
    sbom = %{
      "bomFormat" => "CycloneDX",
      "components" => []
    }

    conn = conn(:post, "/v1/analyze/sbom", %{"sbom" => sbom})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 422
    json = Poison.decode!(conn.resp_body)
    assert json["error"] =~ "no git URLs found"
  end

  test "POST /v1/analyze/sbom with invalid format returns 422" do
    sbom = %{"invalid" => "format"}

    conn = conn(:post, "/v1/analyze/sbom", %{"sbom" => sbom})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 422
    json = Poison.decode!(conn.resp_body)
    assert json["error"] =~ "SBOM parse error"
  end

  test "POST /v1/analyze/sbom without sbom field returns 422" do
    conn = conn(:post, "/v1/analyze/sbom", %{})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 422
    json = Poison.decode!(conn.resp_body)
    assert json["error"] =~ "must contain 'sbom' field"
  end

  test "POST /v1/analyze/sbom with invalid cache_mode returns 422" do
    sbom = %{
      "bomFormat" => "CycloneDX",
      "components" => [
        %{"purl" => "pkg:github/owner/repo@1.0.0"}
      ]
    }

    conn = conn(:post, "/v1/analyze/sbom", %{"sbom" => sbom, "cache_mode" => "invalid"})
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)

    assert conn.status == 422
    json = Poison.decode!(conn.resp_body)
    assert json["error"] =~ "invalid cache_mode"
  end
end
