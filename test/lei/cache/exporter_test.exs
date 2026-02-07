# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.ExporterTest do
  use ExUnit.Case

  @sample_report %{
    header: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      uuid: "test-uuid",
      start_time: "2026-01-01T00:00:00Z",
      end_time: "2026-01-01T00:00:05Z",
      duration: 5,
      source_client: "test",
      library_version: "0.9.0"
    },
    data: %{
      repo: "https://github.com/kitplummer/xmpp4rails",
      risk: "critical",
      git: %{hash: "abc123", default_branch: "main"},
      project_types: %{"npm" => true},
      results: %{
        contributor_count: 1,
        contributor_risk: "critical",
        commit_currency_weeks: 100,
        commit_currency_risk: "critical",
        functional_contributors_risk: "critical",
        functional_contributors: 1,
        large_recent_commit_risk: "low",
        sbom_risk: "medium"
      }
    }
  }

  setup do
    try do
      :ets.delete(:lei_cache)
    rescue
      ArgumentError -> :ok
    end

    try do
      :dets.close(:lei_cache_dets)
    rescue
      _ -> :ok
    end

    tmp = System.tmp_dir!()
    test_id = :rand.uniform(100_000)
    test_cache_dir = Path.join(tmp, "lei_cache_test_#{test_id}")
    test_export_dir = Path.join(tmp, "lei_export_test_#{test_id}")
    File.mkdir_p!(test_cache_dir)
    File.mkdir_p!(test_export_dir)

    Application.put_env(:lowendinsight, :cache_dir, test_cache_dir)

    Lei.Cache.init()

    on_exit(fn ->
      try do
        Lei.Cache.clear()
        Lei.Cache.close()
      rescue
        _ -> :ok
      end

      try do
        :ets.delete(:lei_cache)
      rescue
        ArgumentError -> :ok
      end

      File.rm_rf!(test_cache_dir)
      File.rm_rf!(test_export_dir)
      Application.delete_env(:lowendinsight, :cache_dir)
    end)

    {:ok, export_dir: test_export_dir}
  end

  test "export returns error when cache is empty" do
    assert {:error, "No cache entries to export"} = Lei.Cache.Exporter.export("/tmp/unused")
  end

  test "export creates bundle with all expected files", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/repo1", @sample_report)
    Lei.Cache.put("https://github.com/test/repo2", @sample_report)

    {:ok, bundle_dir, _manifest} = Lei.Cache.Exporter.export(export_dir)

    assert File.exists?(Path.join(bundle_dir, "manifest.json"))
    assert File.exists?(Path.join(bundle_dir, "cache.db"))
    assert File.exists?(Path.join(bundle_dir, "cache.jsonl.gz"))
    assert File.exists?(Path.join(bundle_dir, "checksums.sha256"))
  end

  test "exported JSONL can be decompressed and parsed", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/repo", @sample_report)

    {:ok, bundle_dir, _} = Lei.Cache.Exporter.export(export_dir)

    compressed = File.read!(Path.join(bundle_dir, "cache.jsonl.gz"))
    decompressed = :zlib.gunzip(compressed)

    lines = String.split(decompressed, "\n", trim: true)
    assert length(lines) == 1

    entry = Poison.decode!(hd(lines))
    assert entry["key"] == "https://github.com/test/repo"
    assert entry["ecosystem"] == "npm"
    assert is_map(entry["report"])
  end

  test "exported SQLite database is queryable", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/repo", @sample_report)

    {:ok, bundle_dir, _} = Lei.Cache.Exporter.export(export_dir)

    db_path = Path.join(bundle_dir, "cache.db")
    {:ok, conn} = Exqlite.Sqlite3.open(db_path)

    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "SELECT count(*) FROM cache_entries")
    {:row, [count]} = Exqlite.Sqlite3.step(conn, stmt)
    assert count == 1
    :ok = Exqlite.Sqlite3.release(conn, stmt)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT key, ecosystem, risk FROM cache_entries LIMIT 1")

    {:row, [key, ecosystem, risk]} = Exqlite.Sqlite3.step(conn, stmt)
    assert key == "https://github.com/test/repo"
    assert ecosystem == "npm"
    assert risk == "critical"

    :ok = Exqlite.Sqlite3.release(conn, stmt)

    {:ok, meta_stmt} =
      Exqlite.Sqlite3.prepare(conn, "SELECT value FROM export_metadata WHERE key = 'format_version'")

    {:row, [version]} = Exqlite.Sqlite3.step(conn, meta_stmt)
    assert version == "1.0"
    :ok = Exqlite.Sqlite3.release(conn, meta_stmt)

    :ok = Exqlite.Sqlite3.close(conn)
  end

  test "manifest contains correct structure", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/npm-repo", @sample_report)

    pypi_report = put_in(@sample_report, [:data, :project_types], %{"pip" => true})
    Lei.Cache.put("https://github.com/test/pypi-repo", pypi_report)

    {:ok, bundle_dir, manifest} = Lei.Cache.Exporter.export(export_dir)

    assert manifest.entries == 2
    assert manifest.ecosystems["npm"] == 1
    assert manifest.ecosystems["pypi"] == 1
    assert manifest.format_version == "1.0"
    assert manifest.exported_at != nil
    assert manifest.oldest_entry != nil

    # Verify the written file matches
    written = File.read!(Path.join(bundle_dir, "manifest.json")) |> Poison.decode!()
    assert written["entries"] == 2
    assert written["format_version"] == "1.0"
  end

  test "checksums file contains SHA-256 hashes", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/repo", @sample_report)

    {:ok, bundle_dir, _} = Lei.Cache.Exporter.export(export_dir)

    checksums = File.read!(Path.join(bundle_dir, "checksums.sha256"))
    lines = String.split(checksums, "\n", trim: true)

    assert length(lines) == 3
    assert Enum.any?(lines, &String.contains?(&1, "cache.jsonl.gz"))
    assert Enum.any?(lines, &String.contains?(&1, "cache.db"))
    assert Enum.any?(lines, &String.contains?(&1, "manifest.json"))

    # Verify a checksum is valid
    [hash, _filename] = lines |> hd() |> String.split("  ")
    assert String.length(hash) == 64
    assert Regex.match?(~r/^[0-9a-f]+$/, hash)
  end

  test "checksums match actual file contents", %{export_dir: export_dir} do
    Lei.Cache.put("https://github.com/test/repo", @sample_report)

    {:ok, bundle_dir, _} = Lei.Cache.Exporter.export(export_dir)

    checksums = File.read!(Path.join(bundle_dir, "checksums.sha256"))

    for line <- String.split(checksums, "\n", trim: true) do
      [expected_hash, filename] = String.split(line, "  ")
      actual_hash =
        :crypto.hash(:sha256, File.read!(Path.join(bundle_dir, filename)))
        |> Base.encode16(case: :lower)

      assert expected_hash == actual_hash, "Checksum mismatch for #{filename}"
    end
  end
end
