# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

defmodule Lei.Cache.ExporterTest do
  use ExUnit.Case, async: true

  alias Lei.Cache.Exporter

  @sample_report %{
    header: %{
      uuid: "test-uuid-1",
      start_time: "2026-02-05T00:00:00Z",
      source_client: "test"
    },
    data: %{
      repo: "https://github.com/example/repo",
      risk: "low",
      git: %{hash: "abc123"},
      results: %{
        contributor_count: 5,
        contributor_risk: "low",
        commit_currency_weeks: 2,
        commit_currency_risk: "low"
      }
    }
  }

  describe "export/3" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-export-test-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "creates manifest.json and cache.jsonl.gz", %{dir: dir} do
      {:ok, ^dir} = Exporter.export([@sample_report], dir)

      assert File.exists?(Path.join(dir, "manifest.json"))
      assert File.exists?(Path.join(dir, "cache.jsonl.gz"))
    end

    test "manifest contains correct metadata", %{dir: dir} do
      {:ok, _} = Exporter.export([@sample_report], dir)

      {:ok, data} = File.read(Path.join(dir, "manifest.json"))
      {:ok, manifest} = Poison.decode(data)

      assert manifest["format_version"] == "1.0"
      assert manifest["entry_count"] == 1
      assert is_binary(manifest["lei_version"])
      assert is_binary(manifest["created"])
      assert is_binary(manifest["content_hash"])
      assert "https://github.com/example/repo" in manifest["repos"]
    end

    test "cache.jsonl.gz contains compressed reports", %{dir: dir} do
      {:ok, _} = Exporter.export([@sample_report], dir)

      {:ok, compressed} = File.read(Path.join(dir, "cache.jsonl.gz"))
      decompressed = :zlib.gunzip(compressed)

      lines = String.split(decompressed, "\n", trim: true)
      assert length(lines) == 1

      {:ok, parsed} = Poison.decode(hd(lines))
      assert parsed["data"]["repo"] == "https://github.com/example/repo"
    end

    test "exports multiple reports", %{dir: dir} do
      report2 = put_in(@sample_report, [:data, :repo], "https://github.com/example/repo2")
      {:ok, _} = Exporter.export([@sample_report, report2], dir)

      {:ok, data} = File.read(Path.join(dir, "manifest.json"))
      {:ok, manifest} = Poison.decode(data)
      assert manifest["entry_count"] == 2
    end

    test "accepts custom date option", %{dir: dir} do
      {:ok, _} = Exporter.export([@sample_report], dir, date: "2026-01-15")

      {:ok, data} = File.read(Path.join(dir, "manifest.json"))
      {:ok, manifest} = Poison.decode(data)
      assert manifest["date"] == "2026-01-15"
    end
  end

  describe "read_jsonl/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-read-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "reads gzipped JSONL files", %{dir: dir} do
      path = Path.join(dir, "test.jsonl.gz")
      data = ~s({"key":"value1"}\n{"key":"value2"}\n)
      File.write!(path, :zlib.gzip(data))

      {:ok, reports} = Exporter.read_jsonl(path)
      assert length(reports) == 2
      assert hd(reports)["key"] == "value1"
    end

    test "reads plain JSONL files", %{dir: dir} do
      path = Path.join(dir, "test.jsonl")
      File.write!(path, ~s({"key":"value"}\n))

      {:ok, reports} = Exporter.read_jsonl(path)
      assert length(reports) == 1
    end

    test "skips malformed lines", %{dir: dir} do
      path = Path.join(dir, "test.jsonl")
      File.write!(path, ~s({"key":"ok"}\nnot json\n{"key":"ok2"}\n))

      {:ok, reports} = Exporter.read_jsonl(path)
      assert length(reports) == 2
    end

    test "returns error for missing file" do
      {:error, msg} = Exporter.read_jsonl("/nonexistent/path/test.jsonl")
      assert msg =~ "Cannot read"
    end
  end

  describe "export with string-keyed reports" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lei-export-strkey-#{:rand.uniform(1_000_000)}")
      on_exit(fn -> File.rm_rf!(dir) end)
      {:ok, dir: dir}
    end

    test "handles reports with string keys in manifest repo extraction", %{dir: dir} do
      report = %{
        "header" => %{"uuid" => "string-key-test"},
        "data" => %{"repo" => "https://github.com/example/string-key-repo"}
      }

      {:ok, ^dir} = Exporter.export([report], dir)

      {:ok, data} = File.read(Path.join(dir, "manifest.json"))
      {:ok, manifest} = Poison.decode(data)
      assert "https://github.com/example/string-key-repo" in manifest["repos"]
    end

    test "uses 'unknown' for reports without repo keys", %{dir: dir} do
      report = %{"status" => "test", "something" => "else"}

      {:ok, ^dir} = Exporter.export([report], dir)

      {:ok, data} = File.read(Path.join(dir, "manifest.json"))
      {:ok, manifest} = Poison.decode(data)
      assert "unknown" in manifest["repos"]
    end
  end

  describe "reports_to_jsonl/1" do
    test "converts reports to newline-delimited JSON" do
      reports = [%{a: 1}, %{b: 2}]
      result = Exporter.reports_to_jsonl(reports)
      lines = String.split(result, "\n", trim: true)
      assert length(lines) == 2
    end
  end
end
