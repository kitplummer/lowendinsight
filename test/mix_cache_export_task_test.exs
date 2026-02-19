# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.CacheExportTaskTest do
  use ExUnit.Case, async: false

  describe "run/1 error paths" do
    test "reports usage error when no input provided" do
      assert catch_exit(Mix.Tasks.Lei.Cache.Export.run([])) == {:shutdown, 1}
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Usage"
    end

    test "reports error for nonexistent repo file" do
      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run(["/nonexistent/file/repos.txt"])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Cannot read"
    end

    test "reports error for nonexistent JSONL input" do
      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run(["--input", "/nonexistent/file/data.jsonl"])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "Error reading"
    end

    test "reports error when JSONL produces empty reports" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-empty-jsonl-#{:rand.uniform(100_000)}.jsonl.gz")
      # Write empty gzipped content (empty JSONL = no reports)
      File.write!(tmp_file, :zlib.gzip(""))
      on_exit(fn -> File.rm(tmp_file) end)

      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run(["--input", tmp_file])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [loaded_msg]}
      assert loaded_msg =~ "Loaded 0 reports"
      assert_received {:mix_shell, :error, [msg]}
      assert msg =~ "No reports"
    end

    test "reports error when push requested without registry" do
      report = %{
        "header" => %{"uuid" => "push-test"},
        "data" => %{"repo" => "https://github.com/test/push-repo"}
      }

      tmp_file = Path.join(System.tmp_dir!(), "lei-push-jsonl-#{:rand.uniform(100_000)}.jsonl.gz")
      File.write!(tmp_file, :zlib.gzip(Poison.encode!(report) <> "\n"))
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-push-out-#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run([
                 "--input",
                 tmp_file,
                 "--output",
                 output_dir,
                 "--push"
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [_loaded]}
      assert_received {:mix_shell, :info, [_exporting]}
      assert_received {:mix_shell, :info, [_written]}
      assert_received {:mix_shell, :info, [_oci_manifest]}
      assert_received {:mix_shell, :error, [registry_msg]}
      assert registry_msg =~ "--registry is required"
    end

    test "reports push error for unreachable registry" do
      report = %{
        "header" => %{"uuid" => "push-fail"},
        "data" => %{"repo" => "https://github.com/test/push-fail"}
      }

      tmp_file = Path.join(System.tmp_dir!(), "lei-pushfail-jsonl-#{:rand.uniform(100_000)}.jsonl.gz")
      File.write!(tmp_file, :zlib.gzip(Poison.encode!(report) <> "\n"))
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-pushfail-out-#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run([
                 "--input",
                 tmp_file,
                 "--output",
                 output_dir,
                 "--push",
                 "--registry",
                 "127.0.0.1:1/test/lei-cache"
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [_loaded]}
      assert_received {:mix_shell, :info, [_exporting]}
      assert_received {:mix_shell, :info, [_written]}
      assert_received {:mix_shell, :info, [_oci_manifest]}
      assert_received {:mix_shell, :info, [pushing]}
      assert pushing =~ "Pushing to"
      assert_received {:mix_shell, :error, [push_error]}
      assert push_error =~ "Push failed"
    end

    test "exports from valid JSONL input" do
      report = %{
        "header" => %{"uuid" => "test"},
        "data" => %{"repo" => "https://github.com/test/repo"}
      }

      tmp_file = Path.join(System.tmp_dir!(), "lei-valid-jsonl-#{:rand.uniform(100_000)}.jsonl.gz")
      File.write!(tmp_file, :zlib.gzip(Poison.encode!(report) <> "\n"))
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-export-out-#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      Mix.Tasks.Lei.Cache.Export.run(["--input", tmp_file, "--output", output_dir])

      assert_received {:mix_shell, :info, [loaded]}
      assert loaded =~ "Loaded 1 reports"
      assert_received {:mix_shell, :info, [exporting]}
      assert exporting =~ "Exporting 1 cache entries"
    end

    test "exports from repo file with local file:// URLs" do
      {:ok, cwd} = File.cwd()
      tmp_file = Path.join(System.tmp_dir!(), "lei-repos-local-#{:erlang.unique_integer([:positive])}.txt")
      File.write!(tmp_file, "# This is a comment\nfile:///#{cwd}\n\n")
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-export-local-#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      Mix.Tasks.Lei.Cache.Export.run([tmp_file, "--output", output_dir])

      assert_received {:mix_shell, :info, [analyzing]}
      assert analyzing =~ "Analyzing 1 repositories"
      assert_received {:mix_shell, :info, [_analyzing_url]}
      assert_received {:mix_shell, :info, [exporting]}
      assert exporting =~ "Exporting 1 cache entries"
      assert_received {:mix_shell, :info, [written]}
      assert written =~ "Cache files written to"
    end

    test "push error with host-only registry (no repo path)" do
      report = %{
        "header" => %{"uuid" => "host-only-test"},
        "data" => %{"repo" => "https://github.com/test/host-only"}
      }

      tmp_file = Path.join(System.tmp_dir!(), "lei-hostonly-jsonl-#{:erlang.unique_integer([:positive])}.jsonl.gz")
      File.write!(tmp_file, :zlib.gzip(Poison.encode!(report) <> "\n"))
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-hostonly-out-#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      assert catch_exit(
               Mix.Tasks.Lei.Cache.Export.run([
                 "--input",
                 tmp_file,
                 "--output",
                 output_dir,
                 "--push",
                 "--registry",
                 "127.0.0.1:1"
               ])
             ) == {:shutdown, 1}

      assert_received {:mix_shell, :info, [_loaded]}
      assert_received {:mix_shell, :info, [_exporting]}
      assert_received {:mix_shell, :info, [_written]}
      assert_received {:mix_shell, :info, [_oci]}
      assert_received {:mix_shell, :info, [pushing]}
      assert pushing =~ "Pushing to"
      assert_received {:mix_shell, :error, [push_error]}
      assert push_error =~ "Push failed"
    end

    test "exports with skipping push (default)" do
      report = %{
        "header" => %{"uuid" => "skip-push-test"},
        "data" => %{"repo" => "https://github.com/test/skip-push"}
      }

      tmp_file = Path.join(System.tmp_dir!(), "lei-skip-jsonl-#{:erlang.unique_integer([:positive])}.jsonl.gz")
      File.write!(tmp_file, :zlib.gzip(Poison.encode!(report) <> "\n"))
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-skip-out-#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      Mix.Tasks.Lei.Cache.Export.run(["--input", tmp_file, "--output", output_dir])

      assert_received {:mix_shell, :info, [_loaded]}
      assert_received {:mix_shell, :info, [_exporting]}
      assert_received {:mix_shell, :info, [_written]}
      assert_received {:mix_shell, :info, [_oci]}
      assert_received {:mix_shell, :info, [skip_msg]}
      assert skip_msg =~ "Skipping push"
    end

    @tag :network
    test "exports from repo file with valid URLs" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-repos-#{:rand.uniform(100_000)}.txt")
      # Write a file with comments and blank lines
      File.write!(tmp_file, "# This is a comment\nhttps://github.com/kitplummer/xmpp4rails\n\n")
      on_exit(fn -> File.rm(tmp_file) end)

      output_dir = Path.join(System.tmp_dir!(), "lei-export-repo-#{:rand.uniform(100_000)}")
      on_exit(fn -> File.rm_rf!(output_dir) end)

      # This test needs network to actually analyze repos
      Mix.Tasks.Lei.Cache.Export.run([tmp_file, "--output", output_dir])

      assert_received {:mix_shell, :info, [analyzing]}
      assert analyzing =~ "Analyzing 1 repositories"
    end
  end
end
