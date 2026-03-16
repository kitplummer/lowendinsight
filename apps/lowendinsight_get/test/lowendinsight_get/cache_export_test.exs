# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule LowendinsightGet.CacheExportTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias LowendinsightGet.Datastore

  @opts LowendinsightGet.Endpoint.init([])
  @token "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJhdWQiOiJKb2tlbiIsImV4cCI6MTY3MDQzNTQ1MSwiaWF0IjoxNjcwNDI4MjUxLCJpc3MiOiJKb2tlbiIsImp0aSI6IjJzbjhyOThiczNiZzNwZWwwZzAwMDA3MiIsIm5iZiI6MTY3MDQyODI1MX0.kQgqr-7lmQtlVeq96hmIIYHEniJq638NQ10VW26kT9k"
  @headers [{"authorization", "Bearer #{@token}"}]

  setup do
    # Clean up test keys
    Redix.command(:redix, ["DEL", "testhost:testorg/testrepo:latest"])
    Redix.command(:redix, ["DEL", "github:export-test/repo1:latest"])
    Redix.command(:redix, ["DEL", "github:export-test/repo2:latest"])
    :ok
  end

  describe "Datastore.export_cache/0" do
    test "exports empty cache" do
      # Ensure we start clean for this specific pattern
      {:ok, keys} = Redix.command(:redix, ["KEYS", "export-test-empty:*"])
      Enum.each(keys, fn key -> Redix.command(:redix, ["DEL", key]) end)

      {:ok, _entries, stats} = Datastore.export_cache()
      assert stats["format_version"] == "1.0"
      assert stats["exported_at"] != nil
    end

    test "exports cached entries with data" do
      # Add test entries
      report1 = %{
        "header" => %{"end_time" => DateTime.to_iso8601(DateTime.utc_now())},
        "data" => %{"test" => 1}
      }

      report2 = %{
        "header" => %{"end_time" => DateTime.to_iso8601(DateTime.utc_now())},
        "data" => %{"test" => 2}
      }

      Redix.command(:redix, [
        "SETEX",
        "github:export-test/repo1:latest",
        3600,
        Poison.encode!(report1)
      ])

      Redix.command(:redix, [
        "SETEX",
        "github:export-test/repo2:latest",
        3600,
        Poison.encode!(report2)
      ])

      {:ok, entries, stats} = Datastore.export_cache()

      # Find our test entries
      test_entries = Enum.filter(entries, fn e -> String.contains?(e["key"], "export-test") end)
      assert length(test_entries) >= 2
      assert stats["count"] >= 2

      # Verify entry structure
      entry = Enum.find(test_entries, fn e -> e["key"] == "github:export-test/repo1:latest" end)
      assert entry["data"]["data"]["test"] == 1
      assert entry["ttl_remaining"] > 0
    end
  end

  describe "Datastore.import_cache/2" do
    test "imports entries" do
      entries = [
        %{
          "key" => "testhost:testorg/testrepo:latest",
          "data" => %{
            "header" => %{"end_time" => DateTime.to_iso8601(DateTime.utc_now())},
            "data" => %{"imported" => true}
          }
        }
      ]

      {:ok, stats} = Datastore.import_cache(entries)

      assert stats["imported"] == 1
      assert stats["skipped"] == 0
      assert stats["errors"] == 0

      # Verify data was imported
      {:ok, value} = Redix.command(:redix, ["GET", "testhost:testorg/testrepo:latest"])
      assert value != nil
      decoded = Poison.decode!(value)
      assert decoded["data"]["imported"] == true
    end

    test "skips existing entries without overwrite" do
      # Pre-populate
      Redix.command(:redix, [
        "SETEX",
        "testhost:testorg/testrepo:latest",
        3600,
        Poison.encode!(%{"existing" => true})
      ])

      entries = [
        %{
          "key" => "testhost:testorg/testrepo:latest",
          "data" => %{"new" => true}
        }
      ]

      {:ok, stats} = Datastore.import_cache(entries, overwrite: false)

      assert stats["imported"] == 0
      assert stats["skipped"] == 1

      # Verify original data preserved
      {:ok, value} = Redix.command(:redix, ["GET", "testhost:testorg/testrepo:latest"])
      decoded = Poison.decode!(value)
      assert decoded["existing"] == true
    end

    test "overwrites existing entries with overwrite option" do
      # Pre-populate
      Redix.command(:redix, [
        "SETEX",
        "testhost:testorg/testrepo:latest",
        3600,
        Poison.encode!(%{"existing" => true})
      ])

      entries = [
        %{
          "key" => "testhost:testorg/testrepo:latest",
          "data" => %{"new" => true}
        }
      ]

      {:ok, stats} = Datastore.import_cache(entries, overwrite: true)

      assert stats["imported"] == 1
      assert stats["skipped"] == 0

      # Verify new data
      {:ok, value} = Redix.command(:redix, ["GET", "testhost:testorg/testrepo:latest"])
      decoded = Poison.decode!(value)
      assert decoded["new"] == true
    end

    test "applies custom TTL" do
      entries = [
        %{
          "key" => "testhost:testorg/testrepo:latest",
          "data" => %{"test" => true}
        }
      ]

      {:ok, stats} = Datastore.import_cache(entries, ttl: 60)

      assert stats["ttl_applied"] == 60

      # Verify TTL was applied
      {:ok, ttl} = Redix.command(:redix, ["TTL", "testhost:testorg/testrepo:latest"])
      assert ttl <= 60
      assert ttl > 0
    end
  end

  describe "Datastore.cache_stats/0" do
    test "returns cache statistics" do
      stats = Datastore.cache_stats()

      assert Map.has_key?(stats, "total_entries")
      assert Map.has_key?(stats, "by_ecosystem")
      assert Map.has_key?(stats, "checked_at")
    end
  end

  describe "Cache endpoint integration" do
    test "GET /v1/cache/stats returns statistics" do
      conn = conn(:get, "/v1/cache/stats")
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      json = Poison.decode!(conn.resp_body)
      assert Map.has_key?(json, "total_entries")
      assert Map.has_key?(json, "by_ecosystem")
    end

    test "GET /v1/cache/export returns export data" do
      conn = conn(:get, "/v1/cache/export")
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      json = Poison.decode!(conn.resp_body)
      assert Map.has_key?(json, "entries")
      assert Map.has_key?(json, "stats")
      assert json["stats"]["format_version"] == "1.0"
    end

    test "POST /v1/cache/import imports entries" do
      entries = [
        %{
          "key" => "testhost:testorg/testrepo:latest",
          "data" => %{"test" => "import via endpoint"}
        }
      ]

      conn = conn(:post, "/v1/cache/import", %{"entries" => entries})
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 200
      json = Poison.decode!(conn.resp_body)
      assert json["success"] == true
      assert json["stats"]["imported"] == 1
    end

    test "POST /v1/cache/import with invalid body returns 422" do
      conn = conn(:post, "/v1/cache/import", %{})
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)

      assert conn.status == 422
      json = Poison.decode!(conn.resp_body)
      assert json["error"] =~ "entries"
    end

    test "round-trip export/import preserves data" do
      # Add a test entry
      original = %{
        "header" => %{"end_time" => DateTime.to_iso8601(DateTime.utc_now())},
        "data" => %{"repo" => "https://github.com/export-test/roundtrip", "risk" => "low"}
      }

      Redix.command(:redix, [
        "SETEX",
        "github:export-test/roundtrip:latest",
        3600,
        Poison.encode!(original)
      ])

      # Export
      conn = conn(:get, "/v1/cache/export")
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)
      export_json = Poison.decode!(conn.resp_body)

      # Find our entry
      entry =
        Enum.find(export_json["entries"], fn e ->
          e["key"] == "github:export-test/roundtrip:latest"
        end)

      assert entry != nil

      # Delete original
      Redix.command(:redix, ["DEL", "github:export-test/roundtrip:latest"])

      # Import just our entry
      conn = conn(:post, "/v1/cache/import", %{"entries" => [entry]})
      conn = Plug.Conn.merge_req_headers(conn, @headers)
      conn = LowendinsightGet.Endpoint.call(conn, @opts)
      assert conn.status == 200

      # Verify data restored
      {:ok, restored} = Redix.command(:redix, ["GET", "github:export-test/roundtrip:latest"])
      restored_data = Poison.decode!(restored)
      assert restored_data["data"]["risk"] == "low"
    end
  end
end
