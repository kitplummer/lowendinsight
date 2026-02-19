# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.CacheImportTaskTest do
  use ExUnit.Case, async: false

  describe "run/1" do
    test "reports usage error when no directory provided" do
      assert catch_exit(Mix.Tasks.Lei.Cache.Import.run([])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage"
    end

    test "reports error for invalid directory" do
      assert catch_exit(
               Mix.Tasks.Lei.Cache.Import.run(["/nonexistent/dir/lei-test-12345"])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [importing_msg]}
      assert importing_msg =~ "Importing"
      assert_received {:mix_shell, :error, [error_msg]}
      assert error_msg =~ "Import failed"
    end

    test "successfully imports valid cache directory" do
      dir = Path.join(System.tmp_dir!(), "lei-import-task-test-#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      manifest = %{
        "format_version" => "1.0",
        "date" => "2026-02-05",
        "lei_version" => "0.9.0",
        "entry_count" => 1,
        "repos" => ["https://github.com/example/repo"]
      }

      report = %{"header" => %{"uuid" => "test"}, "data" => %{"repo" => "https://example.com"}}

      File.write!(Path.join(dir, "manifest.json"), Poison.encode!(manifest))
      File.write!(Path.join(dir, "cache.jsonl.gz"), :zlib.gzip(Poison.encode!(report) <> "\n"))

      Mix.Tasks.Lei.Cache.Import.run([dir])

      assert_received {:mix_shell, :info, [_importing]}
      assert_received {:mix_shell, :info, [""]}
      assert_received {:mix_shell, :info, ["=== LEI Cache Import Summary ==="]}
      assert_received {:mix_shell, :info, [date_line]}
      assert date_line =~ "2026-02-05"
    end
  end
end
