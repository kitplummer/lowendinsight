defmodule LowendinsightGet.AnalysisTest do
  use ExUnit.Case, async: false
  use Plug.Test

  @opts LowendinsightGet.Endpoint.init([])
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJKb2tlbiIsImV4cCI6MTY3MDQzNTQ1MSwiaWF0IjoxNjcwNDI4MjUxLCJpc3MiOiJKb2tlbiIsImp0aSI6IjJzbjhyOThiczNiZzNwZWwwZzAwMDA3MiIsIm5iZiI6MTY3MDQyODI1MX0.kQgqr-7lmQtlVeq96hmIIYHEniJq638NQ10VW26kT9k"
  @headers [{"authorization", "Bearer #{@token}"}]

  setup do
    # Use a unique DB prefix per test to avoid collisions
    Redix.command(:redix, ["FLUSHDB"])

    on_exit(fn ->
      Task.Supervisor.children(LowendinsightGet.AnalysisSupervisor)
      |> Enum.map(fn child ->
        Task.Supervisor.terminate_child(LowendinsightGet.AnalysisSupervisor, child)
      end)
    end)
  end

  describe "process_urls/3" do
    test "returns error for invalid URLs" do
      uuid = UUID.uuid1()
      start_time = DateTime.utc_now()

      assert {:error, "invalid URLs list"} ==
               LowendinsightGet.Analysis.process_urls(
                 ["htps://invalid-url"],
                 uuid,
                 start_time
               )
    end

    test "returns complete immediately when all URLs are cached" do
      url = "https://github.com/kitplummer/xmpp4rails"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      # Pre-populate cache with a valid report
      report = %{
        data: %{
          repo: url,
          config: %{},
          results: %{
            commit_currency_risk: "critical",
            commit_currency_weeks: 500,
            contributor_count: 1,
            contributor_risk: "critical",
            functional_contributor_names: ["Test"],
            functional_contributors: 1,
            functional_contributors_risk: "critical",
            large_recent_commit_risk: "low",
            recent_commit_size_in_percent_of_codebase: 0.001,
            top10_contributors: [%{"Test" => 5}]
          },
          risk: "critical"
        },
        header: %{
          duration: 1,
          end_time: now,
          library_version: "",
          source_client: "test",
          start_time: now,
          uuid: "cached-report-uuid"
        }
      }

      LowendinsightGet.Datastore.write_to_cache(url, report)

      uuid = UUID.uuid1()
      start_time = DateTime.utc_now()

      {:ok, json} = LowendinsightGet.Analysis.process_urls([url], uuid, start_time)
      result = Poison.decode!(json)

      assert result["state"] == "complete"
      assert result["metadata"]["cache_status"]["hits"] == 1
      assert result["metadata"]["cache_status"]["misses"] == 0
    end

    @tag timeout: 180_000
    test "queues analysis for uncached URLs and returns incomplete report" do
      url = "https://github.com/kitplummer/goa"
      # Ensure not cached
      key = LowendinsightGet.Datastore.cache_key(url)
      Redix.command(:redix, ["DEL", key])

      uuid = UUID.uuid1()
      start_time = DateTime.utc_now()

      {:ok, json} = LowendinsightGet.Analysis.process_urls([url], uuid, start_time)
      result = Poison.decode!(json)

      # Initially incomplete since analysis is queued
      assert result["state"] == "incomplete"
      assert is_list(result["report"]["repos"])
    end
  end

  describe "analyze/3 cache interaction" do
    @tag timeout: 180_000
    test "returns :miss on first call then :hit on second call" do
      url = "https://github.com/kitplummer/goa"
      key = LowendinsightGet.Datastore.cache_key(url)
      Redix.command(:redix, ["DEL", key])

      {:ok, _report, status1} = LowendinsightGet.Analysis.analyze(url, "test", %{types: false})
      assert status1 == :miss

      {:ok, _report, status2} = LowendinsightGet.Analysis.analyze(url, "test", %{types: false})
      assert status2 == :hit
    end
  end

  describe "full async flow via endpoint" do
    @tag timeout: 180_000
    test "POST /v1/analyze then poll GET /v1/analyze/:uuid until complete" do
      url = "https://github.com/kitplummer/goa"
      key = LowendinsightGet.Datastore.cache_key(url)
      Redix.command(:redix, ["DEL", key])

      # POST to start analysis
      conn = conn(:post, "/v1/analyze", %{urls: [url]})
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      body = Poison.decode!(conn.resp_body)
      uuid = body["uuid"]
      assert uuid != nil

      # Poll until complete (up to 60 seconds)
      final_state = poll_until_complete(uuid, 60)
      assert final_state["state"] == "complete"
      assert is_list(final_state["report"]["repos"])
      assert length(final_state["report"]["repos"]) > 0
    end

    @tag timeout: 180_000
    test "GET /v1/analyze/:uuid returns 404 for nonexistent job" do
      conn = conn(:get, "/v1/analyze/nonexistent-uuid-12345")
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 404
      body = Poison.decode!(conn.resp_body)
      assert body["error"] =~ "invalid UUID"
    end

    @tag timeout: 180_000
    test "cached results include cache_status metadata" do
      url = "https://github.com/kitplummer/goa"

      # First run - populates cache
      key = LowendinsightGet.Datastore.cache_key(url)
      Redix.command(:redix, ["DEL", key])

      conn = conn(:post, "/v1/analyze", %{urls: [url]})
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)
      assert conn.status == 200
      body1 = Poison.decode!(conn.resp_body)

      # Wait for first analysis to complete
      poll_until_complete(body1["uuid"], 60)

      # Second run - should hit cache
      conn2 = conn(:post, "/v1/analyze", %{urls: [url]})
      conn2 = Plug.Conn.merge_req_headers(conn2, @headers)
      conn2 = LowendinsightGet.Endpoint.call(conn2, @opts)
      assert conn2.status == 200
      body2 = Poison.decode!(conn2.resp_body)

      # Poll for second job
      result = poll_until_complete(body2["uuid"], 30)
      assert result["state"] == "complete"
      assert result["metadata"]["cache_status"]["hits"] >= 1
    end
  end

  describe "refresh_job/1" do
    test "completes job when all repos are now cached" do
      url = "https://github.com/kitplummer/xmpp4rails"
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      # Pre-populate cache
      report = %{
        data: %{
          repo: url,
          config: %{},
          results: %{commit_currency_risk: "low"},
          risk: "low"
        },
        header: %{
          end_time: now,
          start_time: now,
          uuid: "cached-uuid"
        }
      }

      LowendinsightGet.Datastore.write_to_cache(url, report)

      # Create an incomplete job referencing this URL
      job = %{
        "uuid" => UUID.uuid1(),
        "state" => "incomplete",
        "report" => %{
          "repos" => [%{"data" => %{"repo" => url}}]
        },
        "metadata" => %{
          "times" => %{
            "start_time" => now,
            "end_time" => "",
            "duration" => 0
          }
        }
      }

      result = LowendinsightGet.Analysis.refresh_job(job)

      assert result["state"] == "complete"
    end
  end

  defp poll_until_complete(uuid, timeout_seconds) do
    poll_until_complete(uuid, timeout_seconds, 0)
  end

  defp poll_until_complete(uuid, timeout_seconds, elapsed) when elapsed >= timeout_seconds do
    # Final attempt
    conn = conn(:get, "/v1/analyze/#{uuid}")
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    Poison.decode!(conn.resp_body)
  end

  defp poll_until_complete(uuid, timeout_seconds, elapsed) do
    conn = conn(:get, "/v1/analyze/#{uuid}")
    conn = Plug.Conn.merge_req_headers(conn, @headers)
    conn = LowendinsightGet.Endpoint.call(conn, @opts)
    body = Poison.decode!(conn.resp_body)

    case body["state"] do
      "complete" ->
        body

      _ ->
        :timer.sleep(2000)
        poll_until_complete(uuid, timeout_seconds, elapsed + 2)
    end
  end
end
