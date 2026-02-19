# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.ImporterTest do
  use ExUnit.Case, async: true

  alias Lei.Cache.Importer

  describe "import_local/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-import-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "imports cache from directory with manifest and jsonl.gz", %{dir: dir} do
      report = %{"header" => %{"uuid" => "test"}, "data" => %{"repo" => "https://example.com/repo"}}

      manifest = %{
        "format_version" => "1.0",
        "date" => "2026-02-05",
        "entry_count" => 1,
        "repos" => ["https://example.com/repo"]
      }

      File.write!(Path.join(dir, "manifest.json"), Poison.encode!(manifest))
      File.write!(Path.join(dir, "cache.jsonl.gz"), :zlib.gzip(Poison.encode!(report) <> "\n"))

      {:ok, imported_manifest, reports} = Importer.import_local(dir)

      assert imported_manifest["date"] == "2026-02-05"
      assert imported_manifest["entry_count"] == 1
      assert length(reports) == 1
      assert hd(reports)["data"]["repo"] == "https://example.com/repo"
    end

    test "returns error for missing manifest", %{dir: dir} do
      assert {:error, msg} = Importer.import_local(dir)
      assert msg =~ "manifest.json"
    end

    test "returns error for missing jsonl.gz", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), ~s({"format_version":"1.0"}))
      assert {:error, msg} = Importer.import_local(dir)
      assert msg =~ "cache"
    end

    test "returns error for invalid JSON in manifest", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), "not valid json{{{")
      File.write!(Path.join(dir, "cache.jsonl.gz"), :zlib.gzip("{}\n"))

      assert {:error, msg} = Importer.import_local(dir)
      assert msg =~ "parse manifest.json"
    end
  end

  describe "pull/3" do
    test "returns error for invalid OCI reference" do
      target_dir = Path.join(System.tmp_dir!(), "lei-pull-test-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf(target_dir) end)

      result = Importer.pull("invalid-no-tag", target_dir)
      assert {:error, _} = result
    end

    test "returns error for unreachable registry" do
      target_dir = Path.join(System.tmp_dir!(), "lei-pull-test-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf(target_dir) end)

      result = Importer.pull("127.0.0.1:1/test/repo:latest", target_dir)
      assert {:error, _} = result
    end

    test "returns error with auth token for unreachable registry" do
      target_dir = Path.join(System.tmp_dir!(), "lei-pull-test-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf(target_dir) end)

      result = Importer.pull("127.0.0.1:1/test/repo:v1", target_dir, token: "test-token")
      assert {:error, _} = result
    end
  end

  describe "round-trip export and import" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-roundtrip-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "exported data can be imported", %{dir: dir} do
      reports = [
        %{
          header: %{uuid: "uuid-1", start_time: "2026-02-05T00:00:00Z"},
          data: %{repo: "https://github.com/example/repo1", risk: "low"}
        },
        %{
          header: %{uuid: "uuid-2", start_time: "2026-02-05T00:00:00Z"},
          data: %{repo: "https://github.com/example/repo2", risk: "medium"}
        }
      ]

      {:ok, export_dir} = Lei.Cache.Exporter.export(reports, dir, date: "2026-02-05")
      {:ok, manifest, imported_reports} = Importer.import_local(export_dir)

      assert manifest["date"] == "2026-02-05"
      assert manifest["entry_count"] == 2
      assert length(imported_reports) == 2

      imported_repos = Enum.map(imported_reports, fn r -> r["data"]["repo"] end)
      assert "https://github.com/example/repo1" in imported_repos
      assert "https://github.com/example/repo2" in imported_repos
    end
  end
end
