# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.Exporter do
  @moduledoc """
  Exports cached LowEndInsight analysis results to a portable bundle
  for air-gapped deployment.

  Output structure:
      lei-cache-YYYY-MM-DD/
      ├── manifest.json
      ├── cache.db          # SQLite
      ├── cache.jsonl.gz    # JSON Lines (gzipped)
      └── checksums.sha256
  """

  @format_version "1.0"

  def export(output_dir \\ nil) do
    entries = Lei.Cache.all_valid()

    if entries == [] do
      {:error, "No cache entries to export"}
    else
      date = Date.utc_today() |> Date.to_iso8601()
      bundle_name = "lei-cache-#{date}"
      base = output_dir || Path.join(System.tmp_dir!(), bundle_name)
      bundle_dir = if output_dir, do: Path.join(output_dir, bundle_name), else: base

      File.mkdir_p!(bundle_dir)

      jsonl_path = Path.join(bundle_dir, "cache.jsonl.gz")
      db_path = Path.join(bundle_dir, "cache.db")
      manifest_path = Path.join(bundle_dir, "manifest.json")
      checksums_path = Path.join(bundle_dir, "checksums.sha256")

      :ok = export_jsonl(entries, jsonl_path)
      :ok = export_sqlite(entries, db_path)

      manifest = build_manifest(entries)
      File.write!(manifest_path, Poison.encode!(manifest, pretty: true))

      checksums = generate_checksums(bundle_dir, ["cache.jsonl.gz", "cache.db", "manifest.json"])
      File.write!(checksums_path, checksums)

      {:ok, bundle_dir, manifest}
    end
  end

  def export_jsonl(entries, path) do
    lines =
      entries
      |> Enum.map(fn {key, entry} ->
        %{
          key: key,
          cached_at: entry.cached_at,
          expires_at: entry.expires_at,
          ecosystem: entry.ecosystem,
          report: entry.report
        }
        |> Poison.encode!()
      end)
      |> Enum.join("\n")

    compressed = :zlib.gzip(lines)
    File.write!(path, compressed)
    :ok
  end

  def export_sqlite(entries, path) do
    File.rm(path)
    {:ok, conn} = Exqlite.Sqlite3.open(path)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE cache_entries (
        key TEXT PRIMARY KEY,
        cached_at INTEGER NOT NULL,
        expires_at INTEGER NOT NULL,
        ecosystem TEXT,
        repo_url TEXT,
        risk TEXT,
        contributor_count INTEGER,
        contributor_risk TEXT,
        commit_currency_weeks REAL,
        commit_currency_risk TEXT,
        report_json TEXT NOT NULL
      )
      """)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE INDEX idx_ecosystem ON cache_entries(ecosystem)
      """)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE INDEX idx_risk ON cache_entries(risk)
      """)

    {:ok, stmt} =
      Exqlite.Sqlite3.prepare(conn, """
      INSERT INTO cache_entries
        (key, cached_at, expires_at, ecosystem, repo_url, risk,
         contributor_count, contributor_risk, commit_currency_weeks,
         commit_currency_risk, report_json)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      """)

    Enum.each(entries, fn {key, entry} ->
      report = entry.report
      results = get_in(report, [:data, :results]) || %{}

      :ok =
        Exqlite.Sqlite3.bind(stmt, [
          key,
          entry.cached_at,
          entry.expires_at,
          entry.ecosystem,
          get_in(report, [:data, :repo]) || key,
          get_in(report, [:data, :risk]),
          results[:contributor_count],
          results[:contributor_risk],
          results[:commit_currency_weeks],
          results[:commit_currency_risk],
          Poison.encode!(report)
        ])

      :done = Exqlite.Sqlite3.step(conn, stmt)
      :ok = Exqlite.Sqlite3.reset(stmt)
    end)

    :ok = Exqlite.Sqlite3.release(conn, stmt)

    :ok =
      Exqlite.Sqlite3.execute(conn, """
      CREATE TABLE export_metadata (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
      """)

    {:ok, meta_stmt} =
      Exqlite.Sqlite3.prepare(conn, "INSERT INTO export_metadata (key, value) VALUES (?1, ?2)")

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    :ok = Exqlite.Sqlite3.bind(meta_stmt, ["exported_at", now])
    :done = Exqlite.Sqlite3.step(conn, meta_stmt)
    :ok = Exqlite.Sqlite3.reset(meta_stmt)

    :ok = Exqlite.Sqlite3.bind(meta_stmt, ["format_version", @format_version])
    :done = Exqlite.Sqlite3.step(conn, meta_stmt)
    :ok = Exqlite.Sqlite3.reset(meta_stmt)

    :ok = Exqlite.Sqlite3.bind(meta_stmt, ["entry_count", to_string(length(entries))])
    :done = Exqlite.Sqlite3.step(conn, meta_stmt)

    :ok = Exqlite.Sqlite3.release(conn, meta_stmt)
    :ok = Exqlite.Sqlite3.close(conn)

    :ok
  end

  def build_manifest(entries) do
    stats = Lei.Cache.stats()

    oldest =
      case entries do
        [] ->
          nil

        _ ->
          {_key, entry} = Enum.min_by(entries, fn {_key, e} -> e.cached_at end)
          entry.cached_at |> DateTime.from_unix!() |> Date.to_string()
      end

    %{
      exported_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      entries: stats.count,
      ecosystems: stats.ecosystems,
      oldest_entry: oldest,
      format_version: @format_version
    }
  end

  defp generate_checksums(bundle_dir, files) do
    files
    |> Enum.map(fn file ->
      path = Path.join(bundle_dir, file)

      if File.exists?(path) do
        hash = :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
        "#{hash}  #{file}"
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end
end
