# Copyright (C) 2020 by the Georgia Tech Research Institute (GTRI)
# This software may be modified and distributed under the terms of
# the BSD 3-Clause license. See the LICENSE file for details.

Mix.shell(Mix.Shell.Process)

defmodule Mix.Tasks.BulkAnalyzeTaskTest do
  use ExUnit.Case, async: false

  describe "run/1 error paths" do
    test "reports invalid file when file does not exist" do
      Mix.Tasks.Lei.BulkAnalyze.run(["/nonexistent/file/repos.txt"])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "invalid file"
    end

    test "reports invalid file contents for non-URL content" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-bulk-invalid-#{:rand.uniform(100_000)}.txt")
      File.write!(tmp_file, "not a valid url\nanother invalid line\n")
      on_exit(fn -> File.rm(tmp_file) end)

      Mix.Tasks.Lei.BulkAnalyze.run([tmp_file])
      assert_received {:mix_shell, :info, [msg]}
      assert msg =~ "invalid file contents"
    end
  end

  describe "run/1 with local file:// URLs (no network)" do
    test "processes file:// URLs with no_validation" do
      {:ok, cwd} = File.cwd()
      tmp_file = Path.join(System.tmp_dir!(), "lei-bulk-local-#{:erlang.unique_integer([:positive])}.txt")
      File.write!(tmp_file, "file:///#{cwd}\n")
      on_exit(fn -> File.rm(tmp_file) end)

      Mix.Tasks.Lei.BulkAnalyze.run([tmp_file, "no_validation"])
      assert_received {:mix_shell, :info, [report]}
      decoded = Poison.decode!(report)
      assert decoded["state"] == "complete"
      assert decoded["metadata"]["repo_count"] == 1
    end

  end

  describe "run/1 with no_validation flag" do
    @describetag :network
    @describetag :long

    test "processes URLs without validation" do
      tmp_file = Path.join(System.tmp_dir!(), "lei-bulk-noval-#{:rand.uniform(100_000)}.txt")

      File.write!(tmp_file, "https://github.com/kitplummer/xmpp4rails\n")
      on_exit(fn -> File.rm(tmp_file) end)

      Mix.Tasks.Lei.BulkAnalyze.run([tmp_file, "no_validation"])
      assert_received {:mix_shell, :info, [report]}
      decoded = Poison.decode!(report)
      assert decoded["state"] == "complete"
    end
  end
end
